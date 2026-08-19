import AppKit
import SwiftUI

/// 列表模式。先出文件名，时长 / 分辨率后到。
struct MediaListView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(env.displayedItems) { item in
                        MediaItemView(
                            item: item,
                            record: env.records[item.id],
                            isSelected: env.selectedIDs.contains(item.id)
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            env.selectFromBrowser(item, modifiers: NSEvent.modifierFlags)
                        }
                        .contextMenu {
                            Button("在访达显示") {
                                env.revealInFinder(item)
                            }

                            Divider()

                            Button("移除列表") {
                                env.removeItemsFromList(ids: env.contextActionIDs(for: item))
                            }
                            .keyboardShortcut(.delete, modifiers: [])

                            Button("删除", role: .destructive) {
                                env.deleteItems(ids: env.contextActionIDs(for: item))
                            }
                            .keyboardShortcut(.delete, modifiers: .shift)
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
