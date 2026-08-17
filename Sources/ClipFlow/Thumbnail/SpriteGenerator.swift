import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 精灵图规格。一次生成，同时供三处使用：格子封面、悬停扫过、进度条预览。
enum SpriteSpec {
    static let frameCount = 24
    static let columns = 6
    static let rows = 4

    /// 精灵图单帧的长边上限。偏小是有意的：悬停扫过时画面在动，
    /// 清晰度不敏感，而体积要乘以帧数再乘以文件数。
    static let maxTileDimension = 144

    /// 格子里显示的封面单独出一张，正方形裁切。
    static let coverSide = 320
    /// 抓封面时的解码上限。要比 coverSide 大，正方形裁切才不会不够像素。
    static let coverSourceMax = 720

    static let startFraction = 0.03
    static let endFraction = 0.97

    static let spriteQuality: CGFloat = 0.75
    static let coverQuality: CGFloat = 0.85
}

/// 用 AVFoundation 抽帧生成精灵图。这是主路径，能覆盖绝大多数素材。
enum SpriteGenerator {

    struct Output: Sendable {
        let spriteJPEG: Data
        /// 每帧的实际时间戳。解码允许小幅偏差，落点不会正好等于请求值，
        /// 悬停位置到帧的映射必须靠这个数组，不能按比例硬算。
        let timestamps: [Double]
        let tileWidth: Int
        let tileHeight: Int
    }

    enum GenerateError: Error, Sendable {
        case noFrames
        case contextFailed
        case encodeFailed
    }

    struct CoverOutput: Sendable {
        let coverJPEG: Data
        let coverTime: Double
        let isFallback: Bool
        /// 实际解了几帧，用于评估这条快路径的成本。
        let framesDecoded: Int
    }

    /// 第一阶段：只出封面。
    ///
    /// 按偏好顺序逐个试候选位置，第一个不是近乎纯色的就用它，因此多数视频
    /// 只解一帧。格子能立刻填满，精灵图留给第二阶段在后台补。
    static func generateCover(
        url: URL,
        info: MediaProbe.Info,
        startFraction: Double = CoverPicker.defaultStartFraction
    ) async throws -> CoverOutput {

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: SpriteSpec.coverSourceMax, height: SpriteSpec.coverSourceMax
        )
        // 单帧封面允许较宽的偏差：这里不需要精确时间点，只要画面像样。
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let fractions = info.duration < CoverPicker.shortClipThreshold
            ? [0.5, 0.3, 0.7]
            : CoverPicker.candidateFractions(startFraction: startFraction)

        var firstImage: CGImage?
        var firstTime = 0.0
        var decoded = 0

        for fraction in fractions {
            let seconds = info.duration * fraction
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            decoded += 1
            if firstImage == nil {
                firstImage = image
                firstTime = seconds
            }
            guard let stats = CoverPicker.stats(for: image), !stats.isNearUniform else {
                continue
            }
            guard let square = squareCrop(image),
                  let data = jpeg(square, quality: SpriteSpec.coverQuality)
            else { continue }
            return CoverOutput(
                coverJPEG: data, coverTime: seconds, isFallback: false, framesDecoded: decoded
            )
        }

        // 候选全是近乎纯色（整条片子基本就是纯色），退回用第一个能解出来的帧
        guard let firstImage,
              let square = squareCrop(firstImage),
              let data = jpeg(square, quality: SpriteSpec.coverQuality)
        else {
            throw GenerateError.noFrames
        }
        return CoverOutput(
            coverJPEG: data, coverTime: firstTime, isFallback: true, framesDecoded: decoded
        )
    }

    /// 第二阶段：完整精灵图，供悬停扫过与进度条预览使用。
    static func generate(url: URL, info: MediaProbe.Info) async throws -> Output {

        let asset = AVURLAsset(url: url)
        let times = sampleTimes(duration: info.duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: SpriteSpec.maxTileDimension,
            height: SpriteSpec.maxTileDimension
        )

        // 时间偏差必须限定在取样间隔的一半以内。
        //
        // 早先这里设的是「无限偏差」——网上通行的抽帧提速做法，代价是每个请求
        // 都会被吸附到最近的关键帧。实测这批素材关键帧极稀疏（很多片子整条只有
        // 开头一个），结果 24 个取样点全部塌缩到同一帧：中位只剩 3 个不同画面，
        // 281 个视频干脆 24 帧全一样。悬停扫过、进度条预览、封面选取会同时失效。
        //
        // 限定偏差后解码要多走几个非关键帧，慢一些，但换来真实的时间分布。
        let interval = info.duration * (SpriteSpec.endFraction - SpriteSpec.startFraction)
            / Double(SpriteSpec.frameCount - 1)
        let tolerance = CMTime(
            seconds: max(0.02, min(interval / 2, 0.5)), preferredTimescale: 600
        )
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames = [CGImage?](repeating: nil, count: times.count)
        var actualTimes = [Double](repeating: 0, count: times.count)
        for (index, time) in times.enumerated() {
            actualTimes[index] = time.seconds
        }

        var cursor = 0
        for await result in generator.images(for: times) {
            guard cursor < frames.count else { break }
            if let image = try? result.image {
                frames[cursor] = image
                if let actual = try? result.actualTime.seconds, actual.isFinite {
                    actualTimes[cursor] = actual
                }
            }
            cursor += 1
        }

        guard frames.contains(where: { $0 != nil }) else { throw GenerateError.noFrames }

        let (spriteData, tileWidth, tileHeight) = try composeSprite(frames: frames)
        return Output(
            spriteJPEG: spriteData,
            timestamps: actualTimes,
            tileWidth: tileWidth,
            tileHeight: tileHeight
        )
    }

    // MARK: - 取样点

    private static func sampleTimes(duration: Double) -> [CMTime] {
        let span = SpriteSpec.endFraction - SpriteSpec.startFraction
        return (0..<SpriteSpec.frameCount).map { index in
            let fraction = SpriteSpec.startFraction
                + span * Double(index) / Double(SpriteSpec.frameCount - 1)
            return CMTime(seconds: duration * fraction, preferredTimescale: 600)
        }
    }

    // MARK: - 拼精灵图

    private static func composeSprite(frames: [CGImage?]) throws -> (Data, Int, Int) {
        guard let reference = frames.compactMap({ $0 }).first else {
            throw GenerateError.noFrames
        }
        let tileWidth = reference.width
        let tileHeight = reference.height

        guard let ctx = CGContext(
            data: nil,
            width: tileWidth * SpriteSpec.columns,
            height: tileHeight * SpriteSpec.rows,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw GenerateError.contextFailed
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .medium

        for (index, frame) in frames.enumerated() {
            guard let frame else { continue }
            let column = index % SpriteSpec.columns
            let row = index / SpriteSpec.columns
            // CGContext 原点在左下，而我们希望第 0 帧在左上
            let rect = CGRect(
                x: column * tileWidth,
                y: (SpriteSpec.rows - 1 - row) * tileHeight,
                width: tileWidth,
                height: tileHeight
            )
            ctx.draw(frame, in: rect)
        }

        guard let image = ctx.makeImage(),
              let data = jpeg(image, quality: SpriteSpec.spriteQuality)
        else {
            throw GenerateError.encodeFailed
        }
        return (data, tileWidth, tileHeight)
    }

    /// 居中正方形裁切并缩到统一边长。
    /// 格子统一方形、画面裁切填满是定好的排布方式：一屏能塞最多，扫起来最快。
    private static func squareCrop(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        let target = SpriteSpec.coverSide
        guard let ctx = CGContext(
            data: nil,
            width: target,
            height: target,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        return ctx.makeImage()
    }

    // MARK: - 编码

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
