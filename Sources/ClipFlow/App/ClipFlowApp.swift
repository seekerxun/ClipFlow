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
        // 系统的窗口恢复会把上次退出时的窗口一并重开，而每扇窗口都自带一套
        // 播放实例。累积几次之后启动就会叠出好几扇窗口：最前面那扇往往是空的，
        // 打开的文件却进了后面某一扇——看起来就是「列表里有、但放不了」。
        // 列表本来就不做会话恢复，这里直接关掉。
        .restorationBehavior(.disabled)
        .commands {
            ClipFlowCommands()
        }

        WindowGroup(id: "opened", for: OpenPayload.self) { $payload in
            WindowRoot(initialURLs: payload?.resolvedURLs ?? [])
        }
        .defaultSize(width: 1280, height: 800)
        .restorationBehavior(.disabled)
    }
}

/// 每个窗口自己的列表和播放，互不影响。
private struct WindowRoot: View {
    /// SwiftUI 每重建一次 `WindowRoot` 结构体，都会把属性默认值重新求一遍。
    /// 直接写 `@State private var environment = AppEnvironment()` 会因此凭空多造
    /// 几套环境，每套都自带一个 mpv 实例；被丢弃的那几套析构时又会把仍挂在屏幕上的
    /// 渲染后端一起卸掉，真正在用的播放器于是永远等不到「渲染就绪」，
    /// 文件只能卡在待播队列里——表现就是列表里有、画面全黑、进度停在 0:00 / 0:00。
    /// 用一个空壳盒子占位，环境只在第一次真正取用时创建。
    @State private var box = EnvironmentBox()
    @Environment(\.openWindow) private var openWindow
    var initialURLs: [URL] = []

    var body: some View {
        content(box.environment)
    }

    @ViewBuilder
    private func content(_ environment: AppEnvironment) -> some View {
        MainView()
            .environment(environment)
            .preferredColorScheme(.dark)
            .focusedSceneValue(\.clipFlowEnvironment, environment)
            .background {
                WindowTitleSync(
                    title: environment.selectedItem?.name ?? "片巡",
                    fileURL: environment.selectedItem?.url
                )
                WindowCloseObserver { window in
                    environment.hostWindow = window
                } onClose: {
                    closeWindow(environment)
                }
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
            // 不要在 `onDisappear` 里拆播放实例。SwiftUI 在启动期会把视图树整体
            // 拆一次再建回来，`onDisappear` 对这种重建和用户关窗一视同仁；照它拆的话
            // 一启动就把还要接着用的播放实例干掉了。清理只认窗口关闭通知。
    }

    /// 只清理本窗口持有的播放实例。`PlaybackController.shutdown()` 可重复调用，
    /// 而且事后还能重建，因而关闭通知和 SwiftUI 视图重建的先后顺序不会留下后遗症。
    private func closeWindow(_ environment: AppEnvironment) {
        environment.playback.shutdown()
        SessionHub.shared.unregister(environment)
    }
}

/// 只为了让环境「按需创建一次」。盒子本身很轻，重复构造无副作用；
/// 里面的 `AppEnvironment` 只有第一次被读到时才真正建出来。
private final class EnvironmentBox {
    private var stored: AppEnvironment?

    @MainActor
    var environment: AppEnvironment {
        if let stored { return stored }
        let created = AppEnvironment()
        stored = created
        return created
    }
}

/// 监听自己所在的那一扇窗口，不能用应用级关闭通知，否则多窗口会互相误伤。
private struct WindowCloseObserver: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWindow: onWindow, onClose: onClose)
    }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        context.coordinator.onWindow = onWindow
        context.coordinator.onClose = onClose
        context.coordinator.observe(window: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator {
        var onWindow: (NSWindow) -> Void
        var onClose: () -> Void
        private weak var window: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var didClose = false

        init(onWindow: @escaping (NSWindow) -> Void, onClose: @escaping () -> Void) {
            self.onWindow = onWindow
            self.onClose = onClose
        }

        deinit {
            stopObserving()
        }

        func observe(window: NSWindow?) {
            if let current = self.window, let window, current === window { return }
            if self.window == nil, window == nil { return }

            stopObserving()
            self.window = window
            guard let window else { return }

            // 换到另一扇窗口就重新计一次。`didClose` 只防同一扇窗口重复触发；
            // 忘了归零的话，启动期那次误报会把真正的关窗一并吃掉，
            // 这扇窗口的播放实例和列表就再也没人回收了。
            didClose = false
            onWindow(window)

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.handleWindowClose()
            }
        }

        func stopObserving() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
            window = nil
        }

        private func handleWindowClose() {
            guard !didClose else { return }
            didClose = true
            onClose()
            stopObserving()
        }
    }
}

private final class WindowObserverView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
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
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            // 底色完全交给 MainView 的单层毛玻璃；窗口本身不再叠一层灰黑色。
            window.backgroundColor = .clear
            window.titlebarSeparatorStyle = .none
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
    /// 字典的遍历顺序是不确定的，直接 `sessions.values.first` 会把文件随机丢给
    /// 某一扇窗口——有时正好是屏幕上那扇，有时是别的，于是同一个操作时灵时不灵。
    /// 这里按注册先后记一份顺序，永远优先最早注册的那个（就是主窗口）。
    private var order: [ObjectIdentifier] = []
    private var sessions: [ObjectIdentifier: AppEnvironment] = [:]
    private var pending: [URL] = []

    private var orderedSessions: [AppEnvironment] {
        order.compactMap { sessions[$0] }
    }

    func register(_ env: AppEnvironment) {
        let id = ObjectIdentifier(env)
        if sessions[id] == nil { order.append(id) }
        sessions[id] = env
    }

    func unregister(_ env: AppEnvironment) {
        let id = ObjectIdentifier(env)
        sessions.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let idle = orderedSessions.first(where: { $0.items.isEmpty }) {
            Task {
                await idle.addURLs(urls)
                // 收下文件的那扇窗口未必在最前面（系统可能刚替我们又开了一扇空窗）。
                // 不提到前面的话，用户看到的是一扇空窗，文件像是没打开。
                bringToFront(idle)
            }
            return
        }
        if let openNewWindow {
            openNewWindow(urls)
            return
        }
        pending.append(contentsOf: urls)
    }

    /// 把持有这份列表的那扇窗口叫到最前面。
    private func bringToFront(_ env: AppEnvironment) {
        guard let window = env.hostWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
