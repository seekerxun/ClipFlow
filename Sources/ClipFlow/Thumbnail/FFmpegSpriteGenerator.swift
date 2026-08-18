import CoreGraphics
import Foundation
import ImageIO

/// AVAssetImageGenerator 失败后的抽帧回退。
///
/// 自动封面与精灵图都用输入 seek（`-ss` 在 `-i` 之前）逐点抽帧：一个取样点一个
/// 进程，解码量与取样点深度无关。早先的做法是一个进程配 `select=` 表达式一次抽完，
/// 看起来更省，实际上 `select=` 逐帧求值，等于从 0 秒顺序解码到片尾 97%，
/// 96 分钟的片子光精灵图就要 51 秒，必然撞上 45 秒闸门。
/// 封面候选沿用主路径的纯色判断，精灵图仍在内存里用 CoreGraphics 拼版。
enum FFmpegSpriteGenerator {

    /// 手动封面只把目标前这一段送进 reverse，限制瞬时内存；精确 seek 会从更早
    /// 的关键帧预解码，因此 GOP 即使跨过窗口边界，滤镜仍能收到窗口起点后的画面。
    private static let manualSeekWindow: Double = 30
    /// 给目标后首帧留出的读取余量。常见视频会在一帧内命中；5 秒也覆盖低帧率
    /// 素材，同时保证损坏时间戳或下游未早停时不会扫描整条长尾。
    private static let manualAfterWindow: Double = 5

    enum GenerateError: Error, Sendable, CustomStringConvertible {
        case noFrames
        case invalidImage
        case encodeFailed
        /// 解码出来的是纯黑帧。退出码、文件大小都正常，只有像素能看出来，
        /// 因此单独成一档，让上层知道这不是「没解出画面」而是「画面无效」。
        case blankFrame

        var description: String {
            switch self {
            case .noFrames: return "ffmpeg 没有解出足够的画面"
            case .invalidImage: return "ffmpeg 输出的图片无效"
            case .encodeFailed: return "ffmpeg 回退图片编码失败"
            case .blankFrame: return "ffmpeg 解出的画面是纯黑帧"
            }
        }
    }

    static func generateCover(
        url: URL,
        info: MediaProbe.Info,
        startFraction: Double = CoverPicker.defaultStartFraction,
        timeout: TimeInterval = 20
    ) async throws -> SpriteGenerator.CoverOutput {
        let executable = try ProcessRunner.executable(named: "ffmpeg")
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appending(path: "cover.png")
        let deadline = Date().addingTimeInterval(timeout)

        let fractions = info.duration < CoverPicker.shortClipThreshold
            ? [0.5, 0.3, 0.7]
            : CoverPicker.candidateFractions(startFraction: startFraction)
        var times: [Double] = []
        for fraction in fractions {
            let time = SpriteSpec.clampedTime(info.duration * fraction, duration: info.duration)
            // 夹到安全上限后多个候选可能重合，去重省掉一次白跑的解码。
            if !times.contains(where: { abs($0 - time) < 0.001 }) { times.append(time) }
        }

        var sawBlank = false
        var decodedCount = 0
        var firstUsable: ExtractedFrame?
        /// 合格就直接给出结果；不合格时记下第一张可用帧留作兜底。
        func consider(_ frame: ExtractedFrame) throws -> SpriteGenerator.CoverOutput? {
            decodedCount += 1
            let stats = CoverPicker.stats(for: frame.image)
            // 纯黑帧连兜底都不用：片尾附近的 seek 会给出退出码正常、结构完整的
            // 全黑图，落成封面就是一个黑格子。
            if stats?.isBlank ?? false {
                sawBlank = true
                return nil
            }
            if firstUsable == nil { firstUsable = frame }
            guard let stats, !stats.isNearUniform else { return nil }
            return try coverOutput(frame: frame, isFallback: false, framesDecoded: decodedCount)
        }

        // 按偏好顺序一个一个试，命中就停，绝大多数视频只解一帧。
        for time in times {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let frame = try await extractFrame(
                executable: executable,
                url: url,
                seek: time,
                filters: coverFilters,
                outputURL: outputURL,
                timeout: remaining
            ) else { continue }
            if let output = try consider(frame) { return output }
        }

        if decodedCount == 0, deadline.timeIntervalSinceNow > 0 {
            let sheet = try await sequentialSheetFrames(
                executable: executable,
                url: url,
                // select= 只能单向前进，联系表按时间升序取；偏好顺序在下面还原。
                times: times.sorted(),
                filters: coverFilters,
                columns: times.count + 1,
                rows: 1,
                outputURL: outputURL,
                timeout: deadline.timeIntervalSinceNow
            )
            for time in times {
                guard let frame = sheet.min(by: {
                    abs($0.time - time) < abs($1.time - time)
                }) else { break }
                if let output = try consider(frame) { return output }
            }
        }
        // 候选全是近乎纯色（整条片子基本就是纯色），退回第一个解出来的帧。
        guard let chosen = firstUsable else {
            throw sawBlank ? GenerateError.blankFrame : GenerateError.noFrames
        }
        return try coverOutput(frame: chosen, isFallback: true, framesDecoded: decodedCount)
    }

    private static func coverOutput(
        frame: ExtractedFrame,
        isFallback: Bool,
        framesDecoded: Int
    ) throws -> SpriteGenerator.CoverOutput {
        guard let jpeg = SpriteGenerator.jpeg(frame.image, quality: SpriteSpec.coverQuality) else {
            throw GenerateError.encodeFailed
        }
        return SpriteGenerator.CoverOutput(
            coverJPEG: jpeg,
            coverTime: frame.time,
            isFallback: isFallback,
            framesDecoded: framesDecoded
        )
    }

    static func generateCover(
        url: URL,
        at seconds: Double,
        timeout: TimeInterval = 20
    ) async throws -> SpriteGenerator.CoverOutput {
        let sheet = try await generateNearestCoverSheet(
            url: url,
            time: max(0, seconds),
            timeout: timeout
        )
        guard let image = sheet.images.first,
              let jpeg = SpriteGenerator.jpeg(image, quality: SpriteSpec.coverQuality)
        else {
            throw GenerateError.invalidImage
        }
        return SpriteGenerator.CoverOutput(
            coverJPEG: jpeg,
            coverTime: sheet.actualTimes.first ?? seconds,
            isFallback: false,
            framesDecoded: sheet.decodedFrameCount
        )
    }

    static func generate(
        url: URL,
        info: MediaProbe.Info,
        timeout: TimeInterval = 45
    ) async throws -> SpriteGenerator.Output {
        let executable = try ProcessRunner.executable(named: "ffmpeg")
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appending(path: "frame.png")
        let deadline = Date().addingTimeInterval(timeout)

        let span = SpriteSpec.endFraction - SpriteSpec.startFraction
        let requestedTimes = (0..<SpriteSpec.frameCount).map { index in
            let fraction = SpriteSpec.startFraction
                + span * Double(index) / Double(SpriteSpec.frameCount - 1)
            return SpriteSpec.clampedTime(info.duration * fraction, duration: info.duration)
        }

        // 24 个取样点各起一个输入 seek 的 ffmpeg 进程。串行足够：实测 96 分钟
        // h264 共 2.3 秒、194 分钟 rv40 共 1.2 秒，离 45 秒闸门有十几倍余量，
        // 而旧的单进程 select= 方案要从 0 秒顺序解到 97%，同一个文件要 51 秒。
        var frames: [CGImage] = []
        var decodedTimes: [Double] = []
        var sawBlank = false
        // 「输入 seek 到底能不能解出画面」的唯一判据。纯黑帧照样算解出来了，
        // 下面的顺序回退只看这个，不看最后留下几张可用帧。
        var decodedAny = false
        for time in requestedTimes {
            let remaining = deadline.timeIntervalSinceNow
            // 预算用完就用已有的帧收尾，剩下的格子由最近帧补，不整张作废。
            guard remaining > 0 else { break }
            guard let frame = try await extractFrame(
                executable: executable,
                url: url,
                seek: time,
                filters: spriteFilters,
                outputURL: outputURL,
                timeout: remaining
            ) else { continue }
            decodedAny = true
            if CoverPicker.stats(for: frame.image)?.isBlank ?? false {
                sawBlank = true
                continue
            }
            // 低帧率素材相邻取样点会落到同一张真实帧，只留一份来源。
            if let last = decodedTimes.last, abs(last - frame.time) < 0.000_001 { continue }
            frames.append(frame.image)
            decodedTimes.append(frame.time)
        }

        // 闸门是「一帧都没解出来」，不是「一张可用帧都没剩下」，和封面那条路的
        // decodedCount == 0 对齐。两者是不同的病：
        // - 一帧都没解出来 = 容器没有索引，顺序解码正是解药；
        // - 解出来了但全是纯黑 = 取样点本身落在黑画面上。顺序解码会经过同样这些
        //   时间点、拿回同样这些黑帧，救不了，却要把整条片子从头解到尾。长片这一
        //   趟要几十秒，必然撞上 45 秒闸门，而且三次重试每次都白烧一遍。
        // 所以这里只治前一种，后一种直接按 blankFrame 失败上报。
        if !decodedAny, deadline.timeIntervalSinceNow > 0 {
            // 输入 seek 一帧都没拿到，整体退回一趟顺序解码。
            for frame in try await sequentialSheetFrames(
                executable: executable,
                url: url,
                times: requestedTimes,
                filters: spriteFilters,
                columns: 5,
                rows: 5,
                outputURL: outputURL,
                timeout: deadline.timeIntervalSinceNow
            ) {
                if CoverPicker.stats(for: frame.image)?.isBlank ?? false {
                    sawBlank = true
                    continue
                }
                if let last = decodedTimes.last, abs(last - frame.time) < 0.000_001 { continue }
                frames.append(frame.image)
                decodedTimes.append(frame.time)
            }
        }
        guard let reference = frames.first else {
            throw sawBlank ? GenerateError.blankFrame : GenerateError.noFrames
        }
        let tileWidth = reference.width
        let tileHeight = reference.height
        guard max(tileWidth, tileHeight) == SpriteSpec.maxTileDimension else {
            throw GenerateError.invalidImage
        }

        let completed = try completeSprite(
            frames: frames,
            decodedTimes: decodedTimes,
            requestedTimes: requestedTimes
        )
        guard let jpeg = SpriteGenerator.jpeg(
            completed.image, quality: SpriteSpec.spriteQuality
        ) else {
            throw GenerateError.encodeFailed
        }
        return SpriteGenerator.Output(
            spriteJPEG: jpeg,
            timestamps: completed.timestamps,
            tileWidth: tileWidth,
            tileHeight: tileHeight
        )
    }

    // MARK: - 单帧抽取

    private struct CoverSheet {
        let images: [CGImage]
        let actualTimes: [Double]
        let decodedFrameCount: Int
    }

    private struct ExtractedFrame {
        let image: CGImage
        let time: Double
    }

    /// 封面按正方形裁切后统一边长；精灵图只等比缩到长边上限。
    private static let coverFilters = [
        "crop=w='min(iw,ih)':h='min(iw,ih)'",
        "scale=\(SpriteSpec.coverSide):\(SpriteSpec.coverSide)"
    ]
    private static let spriteFilters = [
        "scale=w='if(gte(iw,ih),\(SpriteSpec.maxTileDimension),-2)'"
            + ":h='if(gte(iw,ih),-2,\(SpriteSpec.maxTileDimension))'"
    ]

    /// 抽一帧：`-ss` 放在 `-i` 之前做输入 seek，一个进程只出一张图。
    ///
    /// 返回 nil 表示「这个时间点没有画面」，不是错误：seek 越过最后一帧时
    /// ffmpeg 退出码仍是 0，只是什么都不写。调用方据此换下一个取样点或退回首帧。
    private static func extractFrame(
        executable: URL,
        url: URL,
        seek: Double?,
        filters: [String],
        outputURL: URL,
        timeout: TimeInterval
    ) async throws -> ExtractedFrame? {
        try Task.checkCancellation()
        // 上一轮的残留文件会被误当成本轮的成功输出，先清掉。
        try? FileManager.default.removeItem(at: outputURL)
        let result: ProcessRunner.Output
        do {
            result = try await ProcessRunner.run(
                executable: executable,
                arguments: commonInputArguments(url: url, seek: seek) + [
                    "-vf", (filters + ["showinfo"]).joined(separator: ","),
                    "-frames:v", "1",
                    "-fps_mode", "vfr",
                    outputURL.path(percentEncoded: false)
                ],
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessRunner.RunnerError {
            // 单个取样点失败（坏区块、单点超时）只丢这一格，不该拖垮整张图。
            // 找不到 ffmpeg 是环境问题，必须原样抛出。
            if case .executableNotFound = error { throw error }
            return nil
        }
        try Task.checkCancellation()
        guard let image = loadImage(outputURL) else { return nil }
        // 落盘的是滤镜链的第一帧。输出停止后滤镜可能再走一帧，showinfo 会多打
        // 一行，因此只取第一条，且必须用真实 PTS，不能拿请求时间凑数。
        guard let time = parseShowInfoTimes(result.stderr).first else { return nil }
        return ExtractedFrame(image: image, time: time)
    }

    /// 输入 seek 一帧都取不到时的顺序回退。
    ///
    /// 无索引容器（典型是只有开头一个关键帧的 MPEG-TS）按时间 seek 会落到 GOP
    /// 中间，其后再没有关键帧，解码器一路读到 EOF，一张图都出不来；单帧素材、
    /// 时长元数据虚高的文件也会让所有取样点落在最后一帧之后。这时改回一趟顺序
    /// 解码：`select=` 在同一条滤镜链里依次越过全部取样点，拼成 columns×rows 的
    /// 联系表，再切回单帧。慢，但只有输入 seek 完全失效时才会走到。
    ///
    /// - Parameter times: 必须按时间升序，`select=` 只能单向前进。
    private static func sequentialSheetFrames(
        executable: URL,
        url: URL,
        times: [Double],
        filters: [String],
        columns: Int,
        rows: Int,
        outputURL: URL,
        timeout: TimeInterval
    ) async throws -> [ExtractedFrame] {
        guard !times.isEmpty, columns * rows > times.count else { return [] }
        try? FileManager.default.removeItem(at: outputURL)
        // 联系表比取样点多留一格给视频首帧：整条素材只有一张实际帧时，
        // 仍有可复制的来源，不会把合法文件判成失败。
        let capacity = columns * rows
        let target = selectedTargetExpression(times: times, selectedIndexOffset: 1)
        let filter = ([
            "select=lt(selected_n\\,\(capacity))"
                + "*if(eq(n\\,0)\\,1\\,gte(t\\,\(target)))"
        ] + filters + ["showinfo", "tile=\(columns)x\(rows)"]).joined(separator: ",")

        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: commonInputArguments(url: url) + [
                "-vf", filter,
                "-frames:v", "1",
                "-fps_mode", "vfr",
                outputURL.path(percentEncoded: false)
            ],
            timeout: timeout
        )
        try Task.checkCancellation()

        let decodedTimes = Array(parseShowInfoTimes(result.stderr).prefix(capacity))
        guard !decodedTimes.isEmpty else { throw GenerateError.noFrames }
        guard let sheet = loadImage(outputURL),
              sheet.width % columns == 0,
              sheet.height % rows == 0
        else { throw GenerateError.invalidImage }
        let tileWidth = sheet.width / columns
        let tileHeight = sheet.height / rows
        return try decodedTimes.enumerated().map { index, time in
            guard let frame = sheet.cropping(to: CGRect(
                x: (index % columns) * tileWidth,
                y: (index / columns) * tileHeight,
                width: tileWidth,
                height: tileHeight
            )) else { throw GenerateError.invalidImage }
            return ExtractedFrame(image: frame, time: time)
        }
    }

    /// `selected_n` 是已经通过 select 的帧数，可让一个解码过程依次越过多个目标点。
    private static func selectedTargetExpression(
        times: [Double],
        selectedIndexOffset: Int = 0
    ) -> String {
        var expression = decimal(times.last ?? 0)
        for index in times.indices.dropLast().reversed() {
            expression = "if(eq(selected_n\\,\(index + selectedIndexOffset))"
                + "\\,\(decimal(times[index]))\\,\(expression))"
        }
        return expression
    }

    /// 指定时间封面需要同时看到目标两侧的真实帧，不能只找“目标之后”的一帧。
    /// 第二路输入从目标前的有界窗口开始精确解码；整个任务仍只有一个 ffmpeg
    /// 进程。目标后没有帧时（例如 2 秒 1fps 请求 1.8 秒）仍可使用前一帧。
    private static func generateNearestCoverSheet(
        url: URL,
        time: Double,
        timeout: TimeInterval
    ) async throws -> CoverSheet {
        let executable = try ProcessRunner.executable(named: "ffmpeg")
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let firstURL = temporary.appending(path: "first.png")
        let beforeURL = temporary.appending(path: "before.png")
        let afterURL = temporary.appending(path: "after-sheet.png")
        let target = decimal(time)
        // trim 的 end 是排他的；加一个极小量可保留恰好位于目标点的真实帧，
        // 同时仍会在读到目标后的第一帧时立刻向 reverse 发出 EOF。
        let beforeEnd = decimal(time + 0.000_001)
        let seekStart = max(0, time - manualSeekWindow)
        let square = "crop=w='min(iw,ih)':h='min(iw,ih)',"
            + "scale=\(SpriteSpec.coverSide):\(SpriteSpec.coverSide)"
        let filter = [
            "[0:v]select='eq(n\\,0)',showinfo@first,\(square)[first]",
            "[1:v]showinfo@window,split=2[beforeSource][afterSource]",
            // reverse 只缓冲有界窗口；showinfo 放在 reverse 前，用最后一条日志
            // 保留被选中画面的归一化真实 PTS。
            "[beforeSource]trim=end=\(beforeEnd),showinfo@before,\(square),"
                + "reverse,select='eq(n\\,0)'[before]",
            // 先保留 seek 后首帧，保证目标之后没有画面时该输出仍能正常结束；
            // 若存在目标后帧，它会成为联系表第二格。
            "[afterSource]select='lt(selected_n\\,2)"
                + "*(eq(n\\,0)+gte(t\\,\(target)))',showinfo@after,"
                + "\(square),tile=2x1[after]"
        ].joined(separator: ";")

        let path = url.path(percentEncoded: false)
        var seekInput: [String] = []
        // 对靠近开头的目标完全不调用 demuxer seek。无索引 TS 在 `-ss 0` 下也可能
        // 丢掉长 GOP 的唯一关键帧；顺序解码开头既可靠，也仍受窗口上限约束。
        if seekStart > 0 {
            seekInput += ["-ss", decimal(seekStart)]
        }
        let boundedDuration = time - seekStart + manualAfterWindow
        seekInput += [
            "-t", decimal(boundedDuration),
            "-autorotate", "-i", path
        ]

        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "info",
                // 保留 seek 前后的同一时间基准，再把容器 start_time（可正可负）
                // 整体平移到 0；滤镜比较、showinfo 和播放器时间因此口径一致。
                "-copyts", "-start_at_zero",
                "-t", "1", "-autorotate", "-i", path
            ] + seekInput + [
                "-filter_complex", filter,
                "-map", "[first]", "-frames:v:0", "1", firstURL.path(percentEncoded: false),
                "-map", "[before]", "-frames:v:1", "1", beforeURL.path(percentEncoded: false),
                "-map", "[after]", "-frames:v:2", "1", afterURL.path(percentEncoded: false)
            ],
            timeout: timeout
        )
        try Task.checkCancellation()

        var candidates: [(image: CGImage, time: Double)] = []
        if let image = loadImage(firstURL),
           let actual = parseShowInfoTimes(result.stderr, label: "showinfo@first").first
        {
            candidates.append((image, actual))
        }
        if let image = loadImage(beforeURL),
           let actual = parseShowInfoTimes(result.stderr, label: "showinfo@before").last
        {
            candidates.append((image, actual))
        }
        let afterTimes = parseShowInfoTimes(result.stderr, label: "showinfo@after")
        if let afterIndex = afterTimes.firstIndex(where: { $0 + 0.000_001 >= time }),
           let sheet = loadImage(afterURL),
           let image = sheet.cropping(to: CGRect(
               x: afterIndex * SpriteSpec.coverSide,
               y: 0,
               width: SpriteSpec.coverSide,
               height: SpriteSpec.coverSide
           ))
        {
            candidates.append((image, afterTimes[afterIndex]))
        }
        guard let nearest = candidates.min(by: {
            abs($0.time - time) < abs($1.time - time)
        }) else {
            throw GenerateError.noFrames
        }
        let decodedFrameCount = parseShowInfoTimes(
            result.stderr, label: "showinfo@window"
        ).count
        return CoverSheet(
            images: [nearest.image],
            actualTimes: [nearest.time],
            decodedFrameCount: decodedFrameCount
        )
    }

    // MARK: - 进程与解析

    /// - Parameter seek: 输入 seek 的目标秒数。放在 `-i` 之前，demuxer 直接跳到
    ///   目标前的关键帧，解码量与目标深度无关；`nil` 或 0 表示顺序读开头
    ///   （无索引容器在 `-ss 0` 下可能丢掉长 GOP 的唯一关键帧）。
    private static func commonInputArguments(url: URL, seek: Double? = nil) -> [String] {
        var arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "info",
            // showinfo 一律返回媒体相对时间，不能把 TS 等容器的原始 PTS 落进索引。
            "-copyts", "-start_at_zero"
        ]
        if let seek, seek > 0 {
            arguments += ["-ss", decimal(seek)]
        }
        arguments += [
            "-autorotate",
            "-i", url.path(percentEncoded: false),
            "-map", "0:v:0", "-an", "-sn", "-dn"
        ]
        return arguments
    }

    private static func parseShowInfoTimes(_ data: Data, label: String? = nil) -> [Double] {
        // 必须容错解码。RealMedia 这类老容器的元数据不是 UTF-8，
        // `String(data:encoding:.utf8)` 会整段返回 nil，showinfo 行随之全部丢失，
        // 一个能正常解码的文件会被判成「没有帧」。
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains(label ?? "showinfo"),
                  let range = line.range(of: "pts_time:")
            else { return nil }
            let suffix = line[range.upperBound...]
            let value = suffix.prefix { !$0.isWhitespace }
            return Double(value)
        }
    }

    /// 低帧率或极短素材可能在 24 个目标点之间根本没有 24 张不同的源帧。
    /// 不足的格子在内存中复制时间上最近的实际帧，时间映射也指向被复制帧的
    /// 真实 PTS，而不是伪造请求时间。
    static func completeSprite(
        frames: [CGImage],
        decodedTimes: [Double],
        requestedTimes: [Double]
    ) throws -> (image: CGImage, timestamps: [Double]) {
        guard !frames.isEmpty,
              frames.count == decodedTimes.count,
              requestedTimes.count == SpriteSpec.frameCount
        else { throw GenerateError.noFrames }

        let tileWidth = frames[0].width
        let tileHeight = frames[0].height
        guard let context = CGContext(
            data: nil,
            width: tileWidth * SpriteSpec.columns,
            height: tileHeight * SpriteSpec.rows,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw GenerateError.invalidImage }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .medium

        var mappedTimes: [Double] = []
        for (index, requested) in requestedTimes.enumerated() {
            let source = decodedTimes.indices.min {
                abs(decodedTimes[$0] - requested) < abs(decodedTimes[$1] - requested)
            } ?? 0
            mappedTimes.append(decodedTimes[source])
            let column = index % SpriteSpec.columns
            let row = index / SpriteSpec.columns
            // CGContext 原点在左下，而第 0 帧要落在左上。
            context.draw(frames[source], in: CGRect(
                x: column * tileWidth,
                y: (SpriteSpec.rows - 1 - row) * tileHeight,
                width: tileWidth,
                height: tileHeight
            ))
        }
        guard let completed = context.makeImage() else { throw GenerateError.invalidImage }
        return (completed, mappedTimes)
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ClipFlow-FFmpeg-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
