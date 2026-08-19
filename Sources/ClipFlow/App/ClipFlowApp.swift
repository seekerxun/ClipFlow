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
    /// 这扇窗口能不能替别人再开一扇。兜底窗口是手工用 AppKit 建的，
    /// 不属于任何 SwiftUI 场景，`openWindow` 在它里面未必管用，
    /// 因此不让它接这个活，免得文件交出去之后没有下文。
    var canOpenSceneWindows = true

    var body: some View {
        content(box.environment)
    }

    @ViewBuilder
    private func content(_ environment: AppEnvironment) -> some View {
        MainView()
            .environment(environment)
            .preferredColorScheme(.dark)
            // 标题交给 SwiftUI 自己写。早先是绕过它直接改窗口，但 SwiftUI 之后
            // 还会按场景再写一遍，把文件名盖回应用名，于是标题时对时不对。
            .navigationTitle(environment.selectedItem?.name ?? "片巡")
            .focusedSceneValue(\.clipFlowEnvironment, environment)
            .background {
                WindowTitleSync(
                    fileURL: environment.selectedItem?.url,
                    isBrowserVisible: environment.isBrowserVisible,
                    browserOnRight: environment.browserOnRight,
                    showBrowser: { environment.isBrowserVisible = true }
                )
                WindowCloseObserver { window in
                    environment.hostWindow = window
                } onClose: {
                    closeWindow(environment)
                }
            }
            .task {
                // 「再开一扇窗口」的能力跟着这扇窗口一起登记，窗口关掉就一并注销。
                // 之前它是一个全局闭包，关窗时没人清，于是「关光再打开」这条路
                // 走的是一扇已经拆掉的窗口留下的闭包。
                var opener: (([URL]) -> Void)?
                if canOpenSceneWindows {
                    opener = { urls in
                        openWindow(id: "opened", value: OpenPayload(urls: urls))
                    }
                }
                SessionHub.shared.register(environment, opener: opener)
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

/// 标题栏上的文件图标（`representedURL`）和窗口本身的外观。
/// 标题文字不在这里写，交给 SwiftUI 的 `navigationTitle`。
private struct WindowTitleSync: NSViewRepresentable {
    var fileURL: URL?
    var isBrowserVisible: Bool
    var browserOnRight: Bool
    var showBrowser: () -> Void

    func makeNSView(context: Context) -> TitleSyncView {
        let view = TitleSyncView()
        view.isHidden = true
        view.apply(
            fileURL: fileURL,
            isBrowserVisible: isBrowserVisible,
            browserOnRight: browserOnRight,
            showBrowser: showBrowser
        )
        return view
    }

    func updateNSView(_ nsView: TitleSyncView, context: Context) {
        nsView.apply(
            fileURL: fileURL,
            isBrowserVisible: isBrowserVisible,
            browserOnRight: browserOnRight,
            showBrowser: showBrowser
        )
    }
}

/// 记住要写的窗口外观，等真的挂进窗口再写。
///
/// 之前这里是「取不到窗口就算了」：视图刚建出来还没挂进窗口，这一趟就被丢掉，
/// 而选中项此后不再变化，也就没有下一趟，这一份设置于是永远补不上。
private final class TitleSyncView: NSView {
    private var fileURL: URL?
    private var isBrowserVisible = true
    private var browserOnRight = false
    private var showBrowser: (() -> Void)?
    private var sidebarAccessory: NSTitlebarAccessoryViewController?
    private var sidebarButton: NSButton?

    func apply(
        fileURL: URL?,
        isBrowserVisible: Bool,
        browserOnRight: Bool,
        showBrowser: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.isBrowserVisible = isBrowserVisible
        self.browserOnRight = browserOnRight
        self.showBrowser = showBrowser
        push()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        push()
    }

    private func push() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.representedURL = self.fileURL
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            // 底色完全交给 MainView 的单层毛玻璃；窗口本身不再叠一层灰黑色。
            window.backgroundColor = .clear
            window.titlebarSeparatorStyle = .none
            self.updateSidebarAccessory(in: window)
        }
    }

    private func updateSidebarAccessory(in window: NSWindow) {
        if isBrowserVisible {
            removeSidebarAccessory(from: window)
            return
        }

        let button: NSButton
        if let sidebarButton {
            button = sidebarButton
        } else {
            button = NSButton()
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = #selector(showBrowserPane)
            button.setFrameSize(NSSize(width: 28, height: 28))
            button.toolTip = "显示素材浏览区"
            button.setAccessibilityLabel("显示素材浏览区")
            button.setAccessibilityIdentifier("show-media-browser")

            let accessory = NSTitlebarAccessoryViewController()
            // 附件视图右对齐；40pt 容器为按钮右侧保留 12pt 空隙，
            // 不会向下侵占或撑高标题栏。
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            container.addSubview(button)
            accessory.view = container
            accessory.layoutAttribute = .right
            sidebarAccessory = accessory
            sidebarButton = button
            window.addTitlebarAccessoryViewController(accessory)
        }

        let symbol = browserOnRight ? "sidebar.right" : "sidebar.left"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "显示素材浏览区")
    }

    private func removeSidebarAccessory(from window: NSWindow) {
        guard let sidebarAccessory,
              let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === sidebarAccessory })
        else { return }
        window.removeTitlebarAccessoryViewController(at: index)
        self.sidebarAccessory = nil
        self.sidebarButton = nil
    }

    @objc private func showBrowserPane() {
        showBrowser?()
    }
}

private struct ClipFlowCommands: Commands {
    @FocusedValue(\.clipFlowEnvironment) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 菜单比窗口先建好，这里顺手把「开一扇新窗口」的能力交给 `SessionHub`，
        // 让它在一扇窗口都没有的时候也能开出第一扇。
        let _ = SessionHub.shared.captureMainOpener { openWindow(id: "main") }
        // 这里不能写 `return`：写了之后面那组菜单就成了永远走不到的死代码。
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
        CommandMenu("播放") {
            Button(env?.playback.isPaused == false ? "暂停" : "播放") {
                env?.playback.togglePlayPause()
            }
            .keyboardShortcut(" ", modifiers: [])
            .disabled(env == nil)

            Divider()

            Toggle("逐帧模式", isOn: Binding(
                get: { env?.playback.isFrameStepMode ?? false },
                set: { _ in env?.toggleFrameStepMode() }
            ))
            .keyboardShortcut("g", modifiers: [])
            .disabled(env == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(env?.isBrowserVisible == true ? "隐藏素材浏览区" : "显示素材浏览区") {
                env?.isBrowserVisible.toggle()
            }
            .keyboardShortcut(.tab, modifiers: [])
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
            Button("全屏") {
                env?.playback.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [])
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
    /// 系统送「打开文件」时是一个文件一条事件，而 AppKit 默认的处理会为每条事件
    /// 各开一扇窗口。一次选中 20 个文件一起打开，就会弹出 20 扇窗口，每扇都自带
    /// 一套播放实例，机器直接被拖垮。这里把这条事件接管过来自己处理，
    /// AppKit 那套「一个文件一扇窗」的默认动作就不会再执行。
    ///
    /// 必须在 `applicationWillFinishLaunching` 里装，晚于这个时机 AppKit 已经
    /// 把自己的处理挂上去并开始收事件了。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// 事件在主线程送达，因此可以直接进主线程隔离的 `SessionHub`。
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let urls = Self.fileURLs(from: event)
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated {
            SessionHub.shared.open(urls)
        }
    }

    private static func fileURLs(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        // 单个文件时直接对象就是文件本身，多个文件时才是一个列表。
        if direct.numberOfItems > 0 {
            return (1...direct.numberOfItems).compactMap { direct.atIndex($0).flatMap(url(from:)) }
        }
        return [url(from: direct)].compactMap { $0 }
    }

    private static func url(from descriptor: NSAppleEventDescriptor) -> URL? {
        guard let coerced = descriptor.coerce(toDescriptorType: typeFileURL) else { return nil }
        return URL(dataRepresentation: coerced.data, relativeTo: nil)
    }

    /// 接管事件后系统不会再走这条回调，留着只是兜底：万一某条路径仍从这里进来，
    /// 也会汇进同一个入口，`SessionHub` 会把重复的文件去掉。
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

    /// 一扇窗口都没有的时候用它开出第一扇。菜单在启动时就建好了，
    /// 因此这个闭包比任何窗口都早拿到手。
    private var openMainWindow: (() -> Void)?
    /// 字典的遍历顺序是不确定的，直接 `sessions.values.first` 会把文件随机丢给
    /// 某一扇窗口——有时正好是屏幕上那扇，有时是别的，于是同一个操作时灵时不灵。
    /// 这里按注册先后记一份顺序，永远优先最早注册的那个（就是主窗口）。
    private var order: [ObjectIdentifier] = []
    private var sessions: [ObjectIdentifier: AppEnvironment] = [:]
    /// 各窗口交上来的「再开一扇窗口」的能力，和窗口一起登记、一起注销，
    /// 因此永远不会用到已经拆掉的那扇窗口留下的闭包。
    private var openers: [ObjectIdentifier: ([URL]) -> Void] = [:]
    private var pending: [URL] = []

    /// 兜底开窗的实现。默认绕开 SwiftUI 直接用 AppKit 开一扇，测试里换掉免得真弹窗。
    var makeFallbackWindow: (() -> Void)?

    /// 一次「打开多个文件」会被系统拆成好几条事件陆续送来。逐条处理的话，
    /// 每条都会各自去找窗口，最后开出好几扇。先把一小段时间内送到的文件攒成一批，
    /// 再统一决定放进哪扇窗口。
    private var batch: [URL] = []
    private var batchTask: Task<Void, Never>?
    /// 攒批的时长。测试里调小，免得干等。
    var batchWindow = Duration.milliseconds(250)

    /// 叫过开窗之后，等多久还没人来取文件，就认定那条路没走通。
    var windowWait = Duration.milliseconds(1500)
    private var rescueTask: Task<Void, Never>?

    private var orderedSessions: [AppEnvironment] {
        order.compactMap { sessions[$0] }
    }

    /// 还活着的窗口里，登记最早的那扇交上来的开窗能力。
    private var liveOpener: (([URL]) -> Void)? {
        order.lazy.compactMap { self.openers[$0] }.first
    }

    func register(_ env: AppEnvironment, opener: (([URL]) -> Void)? = nil) {
        let id = ObjectIdentifier(env)
        if sessions[id] == nil { order.append(id) }
        sessions[id] = env
        openers[id] = opener
    }

    func unregister(_ env: AppEnvironment) {
        let id = ObjectIdentifier(env)
        sessions.removeValue(forKey: id)
        openers.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    func captureMainOpener(_ opener: @escaping () -> Void) {
        openMainWindow = opener
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 同一批里重复的文件只留一份：兜底回调和事件处理可能把同一个文件送两遍。
        for url in urls where !batch.contains(url) { batch.append(url) }
        batchTask?.cancel()
        batchTask = Task { [weak self, wait = batchWindow] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flushBatch()
        }
    }

    private func flushBatch() {
        let urls = batch
        batch = []
        batchTask = nil
        guard !urls.isEmpty else { return }
        deliver(urls)
    }

    private func deliver(_ urls: [URL]) {
        if let idle = orderedSessions.first(where: { $0.items.isEmpty }) {
            Task {
                await idle.addURLs(urls)
                // 收下文件的那扇窗口未必在最前面。不提到前面的话，
                // 用户看到的是一扇空窗，文件像是没打开。
                bringToFront(idle)
            }
            return
        }
        if let liveOpener {
            liveOpener(urls)
            return
        }
        // 一扇窗口都没有：文件先存着，等新窗口起来自己来取。
        // 已经在等窗口的话就只是搭个车，不要再叫一扇，否则又会多出空窗口。
        let alreadyWaiting = !pending.isEmpty
        pending.append(contentsOf: urls)
        guard !alreadyWaiting else { return }
        requestWindow()
    }

    /// 开出第一扇窗口。首选启动时拿到的那条 SwiftUI 路径——但它是菜单求值时
    /// 顺手记下的副作用，没有任何先后保证，因此这里不当它必然存在：
    /// 拿不到就直接用 AppKit 开；拿到了也留一个看门狗，万一叫了却没开出窗口，
    /// 文件会一直躺在 `pending` 里，用户既看不到窗口也看不到报错。
    private func requestWindow() {
        rescueTask?.cancel()
        rescueTask = nil
        guard let openMainWindow else {
            openFallbackWindow()
            return
        }
        openMainWindow()
        rescueTask = Task { [weak self, wait = windowWait] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.rescuePending()
        }
    }

    /// 看门狗到点，文件还没人取。
    private func rescuePending() {
        rescueTask = nil
        guard !pending.isEmpty else { return }
        guard !sessions.isEmpty else {
            // 还是一扇窗口都没有，那条路确实没走通，自己开一扇。
            openFallbackWindow()
            return
        }
        // 窗口起来了却没来取，直接送过去。
        let urls = pending
        pending = []
        deliver(urls)
    }

    private func openFallbackWindow() {
        if let makeFallbackWindow {
            makeFallbackWindow()
            return
        }
        FallbackWindow.open()
    }

    /// 把持有这份列表的那扇窗口叫到最前面。
    private func bringToFront(_ env: AppEnvironment) {
        guard let window = env.hostWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func takePending() -> [URL] {
        // 有窗口来取文件了，看门狗就不用再守着。
        rescueTask?.cancel()
        rescueTask = nil
        let urls = pending
        pending = []
        return urls
    }
}

/// 最后的兜底：SwiftUI 那条开窗路径没生效时，绕开它直接用 AppKit 开一扇窗口。
/// 里面装的还是同一套 `WindowRoot`，因此拿到文件之后的表现和普通窗口一致。
///
/// 这条路正常永远不会走到。留着是因为另一条路的入口是 SwiftUI 求值菜单时的副作用，
/// 一旦它没跑，文件就会无声无息地消失——宁可多开一扇不那么标准的窗口。
@MainActor
private enum FallbackWindow {
    /// 手工建出来的窗口没人替我们留引用，得自己拿着，等它关掉再放手。
    private static var windows: [NSWindow] = []

    static func open() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "片巡"
        window.contentView = NSHostingView(rootView: WindowRoot(canOpenSceneWindows: false))
        window.center()
        windows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === window }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
