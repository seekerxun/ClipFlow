import SwiftUI

/// 素材浏览区容器。V1 只有列表；网格是 V1.1。
struct MediaBrowserView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MediaListView()
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(env.folderURL?.lastPathComponent ?? "素材")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(env.items.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                env.browserOnRight.toggle()
            } label: {
                Image(systemName: env.browserOnRight
                      ? "sidebar.right"
                      : "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(env.browserOnRight ? "移到左侧" : "移到右侧")
            Button {
                env.isBrowserVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("隐藏素材浏览区")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
