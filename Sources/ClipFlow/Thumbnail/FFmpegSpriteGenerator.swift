import CoreGraphics
import Foundation
import ImageIO

/// AVAssetImageGenerator 失败后的抽帧回退。
///
/// 每次封面或精灵图任务只启动一个 ffmpeg 进程。封面候选先由一次解码组成临时
/// 联系表，再在内存中沿用主路径的纯色判断；精灵图则在同一条滤镜链中完成取样和排版。
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

        var description: String {
            switch self {
            case .noFrames: return "ffmpeg 没有解出足够的画面"
            case .invalidImage: return "ffmpeg 输出的图片无效"
            case .encodeFailed: return "ffmpeg 回退图片编码失败"
            }
        }
    }

    static func generateCover(
        url: URL,
        info: MediaProbe.Info,
        startFraction: Double = CoverPicker.defaultStartFraction,
        timeout: TimeInterval = 20
    ) async throws -> SpriteGenerator.CoverOutput {
        let fractions = info.duration < CoverPicker.shortClipThreshold
            ? [0.5, 0.3, 0.7]
            : CoverPicker.candidateFractions(startFraction: startFraction)
        let candidates = fractions.enumerated().map {
            Candidate(preference: $0.offset, time: info.duration * $0.element)
        }.sorted { $0.time < $1.time }

        let sheet = try await generateCoverSheet(
            url: url,
            times: candidates.map(\.time),
            timeout: timeout
        )
        guard sheet.images.count == candidates.count,
              sheet.actualTimes.count == candidates.count
        else {
            throw GenerateError.noFrames
        }

        var decoded: [(preference: Int, image: CGImage, time: Double)] = []
        for (index, candidate) in candidates.enumerated() {
            decoded.append((candidate.preference, sheet.images[index], sheet.actualTimes[index]))
        }
        decoded.sort { $0.preference < $1.preference }
        guard let first = decoded.first else { throw GenerateError.noFrames }

        var inspected = 0
        for candidate in decoded {
            inspected += 1
            guard let stats = CoverPicker.stats(for: candidate.image), !stats.isNearUniform else {
                continue
            }
            guard let jpeg = SpriteGenerator.jpeg(
                candidate.image, quality: SpriteSpec.coverQuality
            ) else {
                throw GenerateError.encodeFailed
            }
            return SpriteGenerator.CoverOutput(
                coverJPEG: jpeg,
                coverTime: candidate.time,
                isFallback: false,
                framesDecoded: inspected
            )
        }

        guard let jpeg = SpriteGenerator.jpeg(first.image, quality: SpriteSpec.coverQuality) else {
            throw GenerateError.encodeFailed
        }
        return SpriteGenerator.CoverOutput(
            coverJPEG: jpeg,
            coverTime: first.time,
            isFallback: true,
            framesDecoded: inspected
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
        let outputURL = temporary.appending(path: "sprite.png")

        let start = info.duration * SpriteSpec.startFraction
        let span = info.duration * (SpriteSpec.endFraction - SpriteSpec.startFraction)
        let interval = span / Double(SpriteSpec.frameCount - 1)
        let requestedTimes = (0..<SpriteSpec.frameCount).map {
            start + Double($0) * interval
        }
        // 中间联系表多留一格给视频首帧。这样即使整条素材只有一张实际帧，仍有
        // 可复制的来源；正常素材则从 25 张来源中为 24 个目标点选时间最近者。
        let sourceColumns = 5
        let sourceRows = 5
        let sourceCapacity = sourceColumns * sourceRows
        let target = "\(decimal(start))+(selected_n-1)*\(decimal(interval))"
        let filter = [
            "select=lt(selected_n\\,\(sourceCapacity))"
                + "*if(eq(n\\,0)\\,1\\,gte(t\\,\(target)))",
            "scale=w='if(gte(iw,ih),\(SpriteSpec.maxTileDimension),-2)'"
                + ":h='if(gte(iw,ih),-2,\(SpriteSpec.maxTileDimension))'",
            "showinfo",
            "tile=\(sourceColumns)x\(sourceRows)"
        ].joined(separator: ",")

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

        let decodedTimes = Array(parseShowInfoTimes(result.stderr).prefix(sourceCapacity))
        guard !decodedTimes.isEmpty else {
            throw GenerateError.noFrames
        }
        guard let image = loadImage(outputURL),
              image.width % sourceColumns == 0,
              image.height % sourceRows == 0
        else {
            throw GenerateError.invalidImage
        }
        let tileWidth = image.width / sourceColumns
        let tileHeight = image.height / sourceRows
        guard max(tileWidth, tileHeight) == SpriteSpec.maxTileDimension else {
            throw GenerateError.invalidImage
        }
        let completed = try completeSprite(
            image: image,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            sourceColumns: sourceColumns,
            sourceRows: sourceRows,
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

    // MARK: - 封面联系表

    private struct Candidate {
        let preference: Int
        let time: Double
    }

    private struct CoverSheet {
        let images: [CGImage]
        let actualTimes: [Double]
        let decodedFrameCount: Int
    }

    private static func generateCoverSheet(
        url: URL,
        times: [Double],
        timeout: TimeInterval
    ) async throws -> CoverSheet {
        guard !times.isEmpty else { throw GenerateError.noFrames }
        let executable = try ProcessRunner.executable(named: "ffmpeg")
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appending(path: "covers.png")

        // 中间表额外保留视频首帧。若候选点之后已无新帧（单帧、1fps 短片），
        // 仍可在内存中把最近的真实帧映射给每个候选，不会把合法素材判成失败。
        let sourceCapacity = times.count + 1
        let target = selectedTargetExpression(times: times, selectedIndexOffset: 1)
        let filter = [
            "select=lt(selected_n\\,\(sourceCapacity))"
                + "*if(eq(n\\,0)\\,1\\,gte(t\\,\(target)))",
            "showinfo",
            "crop=w='min(iw,ih)':h='min(iw,ih)'",
            "scale=\(SpriteSpec.coverSide):\(SpriteSpec.coverSide)",
            "tile=\(sourceCapacity)x1"
        ].joined(separator: ",")
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

        let decodedTimes = Array(parseShowInfoTimes(result.stderr).prefix(sourceCapacity))
        guard !decodedTimes.isEmpty,
              let image = loadImage(outputURL),
              image.width >= sourceCapacity * SpriteSpec.coverSide,
              image.height >= SpriteSpec.coverSide
        else { throw GenerateError.invalidImage }

        let decodedFrames: [CGImage] = try decodedTimes.indices.map { index in
            guard let frame = image.cropping(to: CGRect(
                x: index * SpriteSpec.coverSide,
                y: 0,
                width: SpriteSpec.coverSide,
                height: SpriteSpec.coverSide
            )) else { throw GenerateError.invalidImage }
            return frame
        }
        var mappedFrames: [CGImage] = []
        var mappedTimes: [Double] = []
        for requested in times {
            let source = decodedTimes.indices.min {
                abs(decodedTimes[$0] - requested) < abs(decodedTimes[$1] - requested)
            } ?? 0
            mappedFrames.append(decodedFrames[source])
            mappedTimes.append(decodedTimes[source])
        }
        return CoverSheet(
            images: mappedFrames,
            actualTimes: mappedTimes,
            decodedFrameCount: decodedTimes.count
        )
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

    private static func commonInputArguments(url: URL) -> [String] {
        [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "info",
            // showinfo 一律返回媒体相对时间，不能把 TS 等容器的原始 PTS 落进索引。
            "-copyts", "-start_at_zero",
            "-autorotate",
            "-i", url.path(percentEncoded: false),
            "-map", "0:v:0", "-an", "-sn", "-dn"
        ]
    }

    private static func parseShowInfoTimes(_ data: Data, label: String? = nil) -> [Double] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
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
    /// ffmpeg 仍只跑一次；不足的格子在内存中复制时间上最近的实际帧，时间映射也
    /// 指向被复制帧的真实 PTS，而不是伪造请求时间。
    static func completeSprite(
        image: CGImage,
        tileWidth: Int,
        tileHeight: Int,
        sourceColumns: Int,
        sourceRows: Int,
        decodedTimes: [Double],
        requestedTimes: [Double]
    ) throws -> (image: CGImage, timestamps: [Double]) {
        guard !decodedTimes.isEmpty,
              decodedTimes.count <= sourceColumns * sourceRows,
              requestedTimes.count == SpriteSpec.frameCount
        else { throw GenerateError.noFrames }

        let frames: [CGImage] = try decodedTimes.indices.map { index in
            let column = index % sourceColumns
            let row = index / sourceColumns
            let rect = CGRect(
                x: column * tileWidth,
                y: row * tileHeight,
                width: tileWidth,
                height: tileHeight
            )
            guard let frame = image.cropping(to: rect) else {
                throw GenerateError.invalidImage
            }
            return frame
        }

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
