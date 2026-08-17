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
        .background(Color(nsColor: NSColor(calibratedWhite: 0.035, alpha: 1)))
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
        .clipFlowInput()
        .onAppear {
            env.applyWindowChrome()
        }
    }

    private var browserPane: some View {
        MediaBrowserView()
            .frame(width: env.sidebarWidth)
    }

    private var playerPane: some View {
        ZStack {
            PlayerView(controller: env.playback)
            if env.items.isEmpty {
                emptyState
            }
        }
        .overlay(alignment: .bottom) {
            TransportBar(controller: env.playback)
                .padding(16)
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if !env.isBrowserVisible {
                showBrowserBar
            }
        }
        .clipped()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("打开视频开始浏览")
                    .font(.headline)
                Text("拖入文件夹或按 ⌘O 添加素材")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                env.promptOpenFolder()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        .padding(.bottom, 48)
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
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .padding(12)
    }

    private var splitter: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.5)
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
        var hasFolder = false
        var hasVideo = false
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                hasFolder = true
            } else if MediaScanner.isVideoFile(url) {
                hasVideo = true
            }
        }
        guard hasFolder || hasVideo else { return false }
        Task { await env.addURLs(urls) }
        return true
    }
}
