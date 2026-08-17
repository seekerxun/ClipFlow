import AppKit
import SwiftUI

/// 列表行：方形缩略图居中裁切 + 文件名。悬停扫过读已生成的精灵图，零解码。
struct MediaItemView: View {
    let item: MediaItem
    let record: IndexRecord?
    let isSelected: Bool

    @State private var hoverFraction: CGFloat?
    @State private var coverImage: NSImage?
    @State private var spriteImage: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .task(id: "\(item.id)-\(record?.coverTime ?? -1)-\(record?.hasSprite == true)") {
            loadImages()
        }
    }

    private var subtitle: String? {
        guard let record else { return nil }
        var parts: [String] = []
        if let duration = record.duration {
            parts.append(DisplayFormat.duration(duration))
        }
        if let width = record.width, let height = record.height {
            parts.append("\(width)×\(height)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var thumbnail: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
                if let hoverFraction, let spriteImage,
                   let tile = spriteTile(spriteImage, fraction: hoverFraction)
                {
                    Image(nsImage: tile)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let width = max(geo.size.width, 1)
                    hoverFraction = min(max(location.x / width, 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
        }
    }

    private func loadImages() {
        let digest = item.key.digest
        if ThumbnailStore.hasCover(digest: digest) {
            coverImage = nsImage(at: ThumbnailStore.coverURL(digest: digest))
        } else {
            coverImage = nil
        }
        if record?.hasSprite == true, ThumbnailStore.hasSprite(digest: digest) {
            spriteImage = nsImage(at: ThumbnailStore.spriteURL(digest: digest))
        } else {
            spriteImage = nil
        }
    }

    private func nsImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func spriteTile(_ image: NSImage, fraction: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let index = frameIndex(fraction: fraction)
        let columns = SpriteSpec.columns
        let rows = SpriteSpec.rows
        let tileWidth = record.flatMap { $0.tileWidth > 0 ? $0.tileWidth : nil } ?? (cg.width / columns)
        let tileHeight = record.flatMap { $0.tileHeight > 0 ? $0.tileHeight : nil } ?? (cg.height / rows)
        let col = index % columns
        let row = index / columns
        // 精灵图第 0 帧画在左上；CGImage 原点也在左上。
        let rect = CGRect(
            x: col * tileWidth,
            y: row * tileHeight,
            width: tileWidth,
            height: tileHeight
        )
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: tileWidth, height: tileHeight))
    }

    private func frameIndex(fraction: CGFloat) -> Int {
        let last = SpriteSpec.frameCount - 1
        let timestamps = record?.spriteTimestamps ?? []
        if timestamps.count == SpriteSpec.frameCount,
           let first = timestamps.first,
           let end = timestamps.last,
           end > first
        {
            let t = first + Double(fraction) * (end - first)
            var best = 0
            var bestDist = Double.infinity
            for (i, stamp) in timestamps.enumerated() {
                let dist = abs(stamp - t)
                if dist < bestDist {
                    bestDist = dist
                    best = i
                }
            }
            return best
        }
        return min(max(Int((fraction * CGFloat(last)).rounded()), 0), last)
    }
}

enum DisplayFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let t = Int(seconds.rounded())
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
