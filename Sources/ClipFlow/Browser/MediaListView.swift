import SwiftUI

/// 列表模式。先出文件名，时长 / 分辨率后到。
struct MediaListView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(env.items) { item in
                        MediaItemView(
                            item: item,
                            record: env.records[item.id],
                            isSelected: item.id == env.selectedID
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { env.select(item) }
                        .onDrag { item.fileDragProvider }
                        .onAppear { env.thumbnails.appear(id: item.id) }
                        .onDisappear { env.thumbnails.disappear(id: item.id) }
                    }
                }
            }
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
