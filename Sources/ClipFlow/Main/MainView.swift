import AppKit
import SwiftUI

/// 主界面：分栏，素材浏览区不覆盖画面。
struct MainView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            if env.isBrowserVisible && !env.browserOnRight {
                browserPane
                splitter
            }
            playerPane
            if env.isBrowserVisible && env.browserOnRight {
                splitter
                browserPane
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
        .clipFlowInput()
    }

    private var browserPane: some View {
        MediaBrowserView()
            .frame(width: env.sidebarWidth)
    }

    private var playerPane: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerView(controller: env.playback)
                if env.items.isEmpty {
                    Text("打开文件夹或把文件夹拖进来")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            TransportBar(controller: env.playback)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !env.isBrowserVisible {
                showBrowserBar
            }
        }
    }

    /// 浏览区收起后仍留在播放区顶部，和标题上的收起箭头成对。
    private var showBrowserBar: some View {
        HStack(spacing: 8) {
            if env.browserOnRight {
                Spacer(minLength: 0)
            }
            Button {
                env.isBrowserVisible = true
            } label: {
                Label("显示素材", systemImage: env.browserOnRight ? "chevron.left" : "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable(false)
            .help("显示素材浏览区")
            .accessibilityLabel("显示素材浏览区")
            if !env.browserOnRight {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var splitter: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStartWidth == nil {
                                    dragStartWidth = env.sidebarWidth
                                }
                                let delta = env.browserOnRight
                                    ? -value.translation.width
                                    : value.translation.width
                                env.sidebarWidth = min(
                                    max((dragStartWidth ?? 320) + delta, 200), 560
                                )
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            }
            .accessibilityLabel("调整浏览区宽度")
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let folder = urls.first { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard let folder else { return false }
        Task { await env.openFolder(folder) }
        return true
    }
}
