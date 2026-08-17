import CoreGraphics
import Foundation

/// 封面帧选取。
///
/// 全部跑在已经生成好的精灵图帧上，零额外解码。
///
/// 刻意保持简单：ffmpegthumbnailer 选「最典型」的帧、ffmpeg 内置滤镜选「最独特」的帧，
/// 两个成熟实现方向相反，说明这个问题没有最优解，继续加码评分函数的回报很低。
/// 真正管用的杠杆是候选时间窗口，以及两个逃生口（可调百分比 + 手动指定）。
enum CoverPicker {

    /// 默认起始位置。业界常见值是 10%，这里取 35% 是针对「短片 + 片头」调的：
    /// 素材普遍只有十几秒，10% 可能还在开场动画里。
    static let defaultStartFraction = 0.35
    static let defaultEndFraction = 0.80

    /// 放宽后的兜底窗口。
    static let fallbackStartFraction = 0.20
    static let fallbackEndFraction = 0.95

    /// 短于这个时长就不做时间偏置——三秒的片子谈不上「片头」。
    static let shortClipThreshold = 4.0

    struct FrameStats: Sendable {
        let meanLuma: Double
        let stdLuma: Double

        /// 近乎纯色：黑场、淡入淡出、白底 logo 卡都会落进来。
        var isNearUniform: Bool {
            meanLuma < 16 || meanLuma > 240 || stdLuma < 12
        }
    }

    struct Choice: Sendable {
        let index: Int
        /// 三个窗口都没有合格帧时为 true，落库后不再重复计算。
        let isFallback: Bool
    }

    /// 第一阶段用的候选位置，按偏好排序。
    ///
    /// 逐个试、第一个合格就停，因此绝大多数视频只需要解一帧。
    /// 前三个落在主窗口内，后两个是放宽后的兜底。
    static func candidateFractions(startFraction: Double = defaultStartFraction) -> [Double] {
        let end = max(startFraction + 0.05, defaultEndFraction)
        let mid = (startFraction + end) / 2
        return [startFraction, mid, end, fallbackStartFraction, fallbackEndFraction]
    }

    static func pick(
        stats: [FrameStats?],
        timestamps: [Double],
        duration: Double,
        startFraction: Double = defaultStartFraction
    ) -> Choice {
        guard !stats.isEmpty, duration > 0 else {
            return Choice(index: 0, isFallback: true)
        }

        let endFraction = max(startFraction + 0.05, defaultEndFraction)

        // 短片直接对全部帧做纯色剔除，不加时间偏置
        if duration < shortClipThreshold {
            if let index = firstAcceptable(stats: stats, indices: Array(stats.indices)) {
                return Choice(index: index, isFallback: false)
            }
            return Choice(index: stats.count / 2, isFallback: true)
        }

        let primary = indices(in: stats, timestamps: timestamps, duration: duration,
                              from: startFraction, to: endFraction)
        if let index = firstAcceptable(stats: stats, indices: primary) {
            return Choice(index: index, isFallback: false)
        }

        let widened = indices(in: stats, timestamps: timestamps, duration: duration,
                              from: fallbackStartFraction, to: fallbackEndFraction)
        if let index = firstAcceptable(stats: stats, indices: widened) {
            return Choice(index: index, isFallback: false)
        }

        return Choice(index: stats.count / 2, isFallback: true)
    }

    private static func indices(
        in stats: [FrameStats?],
        timestamps: [Double],
        duration: Double,
        from: Double,
        to: Double
    ) -> [Int] {
        stats.indices.filter { index in
            guard index < timestamps.count else { return false }
            let fraction = timestamps[index] / duration
            return fraction >= from && fraction <= to
        }
    }

    private static func firstAcceptable(stats: [FrameStats?], indices: [Int]) -> Int? {
        indices.first { index in
            guard let s = stats[index] else { return false }
            return !s.isNearUniform
        }
    }

    // MARK: - 帧统计

    /// 把一帧缩到 32×32 灰度后算亮度均值与标准差。
    /// 缩到这么小是有意的：我们要判断的是整帧的明暗分布，不是细节。
    static func stats(for image: CGImage) -> FrameStats? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)

        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }

        let total = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / total
        let variance = pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / total
        return FrameStats(meanLuma: mean, stdLuma: sqrt(variance))
    }
}
