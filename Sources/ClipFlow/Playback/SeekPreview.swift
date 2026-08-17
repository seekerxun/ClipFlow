import AppKit
import SwiftUI

/// 进度条 hover 预览。只读已生成的精灵图，不解码、不开第二个播放实例。
struct SeekPreview: View {
    let image: NSImage
    let time: Double

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: CGFloat(SpriteSpec.maxTileDimension),
                    maxHeight: CGFloat(SpriteSpec.maxTileDimension)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)

            Text(DisplayFormat.duration(time))
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.bar, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .allowsHitTesting(false)
    }

    /// 把播放时间映射到精灵图帧下标。有 24 个实际时间戳时取最近的一帧；
    /// 否则按时长均匀切 24 段，避免卡住拖动。
    static func frameIndex(time: Double, timestamps: [Double], duration: Double) -> Int {
        let last = SpriteSpec.frameCount - 1
        if timestamps.count == SpriteSpec.frameCount {
            var best = 0
            var bestDist = Double.infinity
            for (i, stamp) in timestamps.enumerated() {
                let dist = abs(stamp - time)
                if dist < bestDist {
                    bestDist = dist
                    best = i
                }
            }
            return best
        }
        guard duration > 0, time.isFinite else { return 0 }
        let fraction = min(max(time / duration, 0), 1)
        return min(max(Int((fraction * Double(last)).rounded()), 0), last)
    }

    static func tile(from sprite: CGImage, record: IndexRecord?, index: Int) -> NSImage? {
        let last = SpriteSpec.frameCount - 1
        let clamped = min(max(index, 0), last)
        let columns = SpriteSpec.columns
        let rows = SpriteSpec.rows
        let tileWidth = record.flatMap { $0.tileWidth > 0 ? $0.tileWidth : nil }
            ?? (sprite.width / columns)
        let tileHeight = record.flatMap { $0.tileHeight > 0 ? $0.tileHeight : nil }
            ?? (sprite.height / rows)
        let col = clamped % columns
        let row = clamped / columns
        // 精灵图第 0 帧画在左上；CGImage 原点也在左上。
        let rect = CGRect(
            x: col * tileWidth,
            y: row * tileHeight,
            width: tileWidth,
            height: tileHeight
        )
        guard let cropped = sprite.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: tileWidth, height: tileHeight))
    }

    /// 磁盘上的 JPEG。没有文件就返回 nil，调用方改用封面或干脆不显示。
    static func loadSprite(digest: String) -> CGImage? {
        guard ThumbnailStore.hasSprite(digest: digest) else { return nil }
        return cgImage(at: ThumbnailStore.spriteURL(digest: digest))
    }

    static func loadCover(digest: String) -> NSImage? {
        guard ThumbnailStore.hasCover(digest: digest) else { return nil }
        return nsImage(at: ThumbnailStore.coverURL(digest: digest))
    }

    private static func nsImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private static func cgImage(at url: URL) -> CGImage? {
        guard let image = nsImage(at: url) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
