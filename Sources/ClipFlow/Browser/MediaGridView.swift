import AppKit
import SwiftUI

/// 网格模式。一屏大约 40–60 个方形缩略图；悬停扫过复用 `MediaItemView`。
///
/// 用 `LazyVGrid`，只给可见格挂 `onAppear`。调度仍走 `ThumbnailQueue`：
/// 可见格 + 前后各一屏，打开时不会把整个目录丢进队列。
struct MediaGridView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns(for: geo.size), spacing: 8) {
                        ForEach(env.displayedItems) { item in
                            MediaItemView(
                                item: item,
                                record: env.records[item.id],
                                isSelected: env.selectedIDs.contains(item.id),
                                layout: .grid
                            )
                            .aspectRatio(1, contentMode: .fit)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                env.selectFromBrowser(item, modifiers: NSEvent.modifierFlags)
                            }
                            .onDrag { item.fileDragProvider }
                            .onAppear { env.thumbnails.appear(id: item.id) }
                            .onDisappear { env.thumbnails.disappear(id: item.id) }
                        }
                    }
                    .padding(8)
                    .background {
                        LightweightScrollerStyle()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .onAppear {
                    if let id = env.selectedID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: env.selectedID) { _, newID in
                    guard env.shouldScrollToSelection, let newID else { return }
                    env.shouldScrollToSelection = false
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    /// 按浏览区尺寸估列数，让一屏格子落在大约 40–60。
    private func columns(for size: CGSize) -> [GridItem] {
        let spacing: CGFloat = 8
        let padding: CGFloat = 16
        let innerW = max(size.width - padding, 1)
        let innerH = size.height > 1 ? max(size.height - padding, 1) : 600
        let estimated = sqrt(50.0 * innerW / innerH)
        let count = min(max(Int(estimated.rounded()), 3), 12)
        return Array(repeating: GridItem(.flexible(minimum: 36), spacing: spacing), count: count)
    }
}
