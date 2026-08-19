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
        .background {
            ZStack {
                DockGlassBackground()
                Color.black.opacity(0.13)
                ChromeTintOverlay()
            }
            .ignoresSafeArea()
        }
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
        VStack(spacing: 0) {
            ZStack {
                PlayerView(controller: env.playback)
                if env.items.isEmpty {
                    Color.black
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(0.45)

            TransportBar(controller: env.playback)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    ZStack {
                        Rectangle()
                            .fill(.thinMaterial)
                            .opacity(0.88)
                        ChromeTintOverlay(opacity: 0.035)
                    }
                }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
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
        .padding(20)
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

/// 统一覆盖在半透明 chrome 材质上的低饱和色雾；画面内容保持在它的上方。
private struct ChromeTintOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let opacity: Double

    init(opacity: Double = 0.055) {
        self.opacity = opacity
    }

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.82, blue: 0.92),
                Color(red: 0.18, green: 0.43, blue: 0.96),
                Color(red: 0.67, green: 0.25, blue: 0.95),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .opacity(effectiveOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var effectiveOpacity: Double {
        guard !reduceTransparency, colorSchemeContrast != .increased else {
            return min(opacity, 0.035)
        }
        return opacity
    }
}

/// 使用与 Dock 接近的系统级窗口毛玻璃：模糊并吸收桌面颜色。
private struct DockGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
