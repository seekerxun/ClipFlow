import AppKit
import SwiftUI

@main
struct ClipFlowMain {
    static func main() {
        // 基准测试模式：不起界面，跑完直接退出
        if Bench.runIfRequested() {
            exit(0)
        }
        ClipFlowApp.main()
    }
}

struct ClipFlowApp: App {
    @NSApplicationDelegateAdaptor(ClipFlowAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRoot()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            ClipFlowCommands()
        }

        WindowGroup(id: "opened", for: OpenPayload.self) { $payload in
            WindowRoot(initialURLs: payload?.resolvedURLs ?? [])
        }
        .defaultSize(width: 1280, height: 800)
    }
}

/// 每个窗口自己的列表和播放，互不影响。
private struct WindowRoot: View {
    @State private var environment = AppEnvironment()
    @Environment(\.openWindow) private var openWindow
    var initialURLs: [URL] = []

    var body: some View {
        MainView()
            .environment(environment)
            .preferredColorScheme(.dark)
            .focusedSceneValue(\.clipFlowEnvironment, environment)
            .background {
                WindowTitleSync(
                    title: environment.selectedItem?.name ?? "片巡",
                    fileURL: environment.selectedItem?.url
                )
            }
            .task {
                SessionHub.shared.register(environment)
                SessionHub.shared.openNewWindow = { urls in
                    openWindow(id: "opened", value: OpenPayload(urls: urls))
                }
                var urls = initialURLs
                if urls.isEmpty {
                    urls = SessionHub.shared.takePending()
                }
                if !urls.isEmpty {
                    await environment.addURLs(urls)
                }
            }
            .onDisappear {
                SessionHub.shared.unregister(environment)
            }
    }
}

/// 窗口标题用正在播的文件名，Dock 右键才能分清多扇窗口。
private struct WindowTitleSync: NSViewRepresentable {
    var title: String
    var fileURL: URL?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.title = title
            window.representedURL = fileURL
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.72)
            window.titlebarSeparatorStyle = .line
        }
    }
}

private struct ClipFlowCommands: Commands {
    @FocusedValue(\.clipFlowEnvironment) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("打开文件夹…") {
                env?.promptOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            // Tab 由窗口收键处理（README 第 8 节），不在这里绑快捷键，
            // 以免和系统切焦点或收键各触发一次。
            Button(env?.isBrowserVisible == true ? "隐藏素材浏览区" : "显示素材浏览区") {
                env?.isBrowserVisible.toggle()
            }
            .disabled(env == nil)
            Button("素材浏览区在左侧") {
                env?.browserOnRight = false
                env?.isBrowserVisible = true
            }
            .disabled(env == nil)
            Button("素材浏览区在右侧") {
                env?.browserOnRight = true
                env?.isBrowserVisible = true
            }
            .disabled(env == nil)
            Divider()
            Button("搜索素材") {
                env?.showSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(env == nil)
        }
    }
}

final class ClipFlowAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            SessionHub.shared.open(urls)
        }
    }
}

/// Finder「打开方式」送来的路径。空窗口就地加入；已有内容则再开一扇。
@MainActor
final class SessionHub {
    static let shared = SessionHub()

    var openNewWindow: (([URL]) -> Void)?
    private var sessions: [ObjectIdentifier: AppEnvironment] = [:]
    private var pending: [URL] = []

    func register(_ env: AppEnvironment) {
        sessions[ObjectIdentifier(env)] = env
    }

    func unregister(_ env: AppEnvironment) {
        sessions.removeValue(forKey: ObjectIdentifier(env))
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let idle = sessions.values.first(where: { $0.items.isEmpty }) {
            Task { await idle.addURLs(urls) }
            return
        }
        if let openNewWindow {
            openNewWindow(urls)
            return
        }
        pending.append(contentsOf: urls)
    }

    func takePending() -> [URL] {
        let urls = pending
        pending = []
        return urls
    }
}

struct OpenPayload: Hashable, Codable {
    var paths: [String]

    init(urls: [URL]) {
        paths = urls.map { $0.path(percentEncoded: false) }
    }

    var resolvedURLs: [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }
}

private struct ClipFlowEnvironmentKey: FocusedValueKey {
    typealias Value = AppEnvironment
}

extension FocusedValues {
    var clipFlowEnvironment: AppEnvironment? {
        get { self[ClipFlowEnvironmentKey.self] }
        set { self[ClipFlowEnvironmentKey.self] = newValue }
    }
}
