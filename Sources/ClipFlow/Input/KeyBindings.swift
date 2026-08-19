import AppKit
import SwiftUI

/// README 第 8 节快捷键。
///
/// 不依赖 SwiftUI 焦点：点过控制条或列表后，系统会把 first responder
/// 交给按钮 / 滑条，`.onKeyPress` 就收不到键。这里用窗口级 keyDown
/// 监视，在派发给控件之前收下左手区按键；Tab 也在这里处理，
/// 避免被系统拿去切焦点。
enum KeyBindings {

    /// 处理一次按键。吞掉返回 true。`Cmd+W` / `Cmd+S` / `Cmd+O` 不占用。
    @MainActor
    static func handle(_ event: NSEvent, env: AppEnvironment) -> Bool {
        guard event.type == .keyDown else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.option) || mods.contains(.control) {
            return false
        }

        if mods.contains(.command) {
            return handleCommand(event, env: env)
        }

        switch event.keyCode {
        case 49: // space
            return once(event) { env.playback.togglePlayPause() }
        case 53: // escape
            env.playback.exitFullscreen()
            return true
        case 123: // left
            return seekOrStep(env, seconds: -5, frames: -1)
        case 124: // right
            return seekOrStep(env, seconds: 5, frames: 1)
        case 126: // up
            return seekOrStep(env, seconds: -30, frames: -10)
        case 125: // down
            return seekOrStep(env, seconds: 30, frames: 10)
        case 116: // pageUp
            env.selectOffset(-1, wrap: false)
            return true
        case 121: // pageDown
            env.selectOffset(1, wrap: false)
            return true
        case 48: // tab：显示 / 隐藏素材浏览区，不交给系统切焦点
            return once(event) { env.isBrowserVisible.toggle() }
        case 33: // [
            return handleLoopBracket(event, env: env, isStart: true)
        case 30: // ]
            return handleLoopBracket(event, env: env, isStart: false)
        default:
            break
        }

        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch ch {
        case " ":
            return once(event) { env.playback.togglePlayPause() }
        case "q":
            env.selectOffset(-1, wrap: false)
            return true
        case "e":
            env.selectOffset(1, wrap: false)
            return true
        case "a":
            return seekOrStep(env, seconds: -5, frames: -1)
        case "d":
            return seekOrStep(env, seconds: 5, frames: 1)
        case "w":
            return seekOrStep(env, seconds: -30, frames: -10)
        case "s":
            return seekOrStep(env, seconds: 30, frames: 10)
        case "g":
            return once(event) { env.toggleFrameStepMode() }
        case "f":
            return once(event) { env.playback.toggleFullscreen() }
        case "l":
            return once(event) { env.playback.cycleLoopMode() }
        case "m":
            return once(event) { env.playback.toggleMute() }
        case "z":
            return once(event) { env.playback.cycleSlowSpeed() }
        case "x":
            return once(event) { env.playback.resetSpeed() }
        case "c":
            return once(event) { env.playback.cycleFastSpeed() }
        case "b":
            return once(event) { env.captureCoverFromCurrentFrame() }
        case "[", "「":
            return handleLoopBracket(event, env: env, isStart: true)
        case "]", "」":
            return handleLoopBracket(event, env: env, isStart: false)
        default:
            return false
        }
    }

    /// 前后跳转。逐帧模式下同一批键改成按帧走，长按仍可连步。
    @MainActor
    private static func seekOrStep(_ env: AppEnvironment, seconds: Double, frames: Int) -> Bool {
        if env.playback.isFrameStepMode {
            env.playback.stepFrame(by: frames)
        } else {
            env.playback.seek(by: seconds)
        }
        return true
    }

    @MainActor
    private static func handleLoopBracket(_ event: NSEvent, env: AppEnvironment, isStart: Bool) -> Bool {
        let shifted = event.modifierFlags.contains(.shift)
        return once(event) {
            if isStart {
                if shifted { env.playback.clearLoopA() } else { env.playback.markLoopA() }
            } else {
                if shifted { env.playback.clearLoopB() } else { env.playback.markLoopB() }
            }
        }
    }

    @MainActor
    private static func handleCommand(_ event: NSEvent, env: AppEnvironment) -> Bool {
        switch event.keyCode {
        case 3 where !event.modifierFlags.contains(.shift): // Cmd+F
            return once(event) { env.showSearch() }
        case 126: // Cmd+↑
            env.selectOffset(-1, wrap: false)
            return true
        case 125: // Cmd+↓
            env.selectOffset(1, wrap: false)
            return true
        default:
            return false
        }
    }

    /// 切换类按键忽略长按重复，但仍吞掉，避免漏到别处。
    private static func once(_ event: NSEvent, _ action: () -> Void) -> Bool {
        if !event.isARepeat { action() }
        return true
    }
}

/// 透明收键视图：可成为 first responder，但不参与点击命中，以免挡住按钮。
final class ClipFlowKeyView: NSView {
    var env: AppEnvironment?

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isMenuTracking = false
    private static var didRestoreFrame = false
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            start()
            if let window {
                if !Self.didRestoreFrame {
                    window.setFrameUsingName("ClipFlowMain")
                    Self.didRestoreFrame = true
                }
                window.setFrameAutosaveName("ClipFlowMain")
            }
            window?.initialFirstResponder = self
            DispatchQueue.main.async { [weak self] in
                self?.reclaimKeyFocus()
                self?.env?.applyWindowChrome()
            }
        } else {
            stop()
        }
    }

    override func keyDown(with event: NSEvent) {
        if consume(event) { return }
        super.keyDown(with: event)
    }

    func start() {
        guard monitors.isEmpty else { return }

        if let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.consume(event) ? nil : event
        }) {
            monitors.append(keyMonitor)
        }

        if let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.endEditingIfClickOutside(event)
            return event
        }) {
            monitors.append(clickMonitor)
        }

        if let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            guard let self else { return event }
            guard event.buttonNumber == 2 else { return event }
            guard self.shouldHandle(in: event.window) else { return event }
            self.env?.playback.toggleFullscreen()
            return nil
        }) {
            monitors.append(mouseMonitor)
        }

        if let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            return self.handlePlayerVolumeScroll(event)
        }) {
            monitors.append(scrollMonitor)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMenuTracking = true
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMenuTracking = false
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reclaimKeyFocus()
        })
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isMenuTracking = false
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    @discardableResult
    private func consume(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if isMenuTracking { return false }
        if NSApp.modalWindow != nil { return false }
        guard let window, window.isKeyWindow, window === self.window else { return false }
        if event.window !== window { return false }
        if window is NSPanel { return false }
        if isEditingText(in: window) {
            return handleSearchEscape(event)
        }
        guard let env else { return false }
        return KeyBindings.handle(event, env: env)
    }

    /// 搜索框有焦点时 Esc 先清空，再按一次收起搜索；不退出全屏。
    private func handleSearchEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        guard let env else { return false }
        if !env.searchText.isEmpty {
            env.searchText = ""
            return true
        }
        env.hideSearch()
        endTextEditing()
        return true
    }

    private func endEditingIfClickOutside(_ event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        if isMenuTracking { return }
        if NSApp.modalWindow != nil { return }
        guard let window, event.window === window else { return }
        guard isEditingText(in: window) else { return }
        if isClickOnTextInput(event, in: window) { return }
        endTextEditing()
    }

    private func endTextEditing() {
        guard let window else { return }
        window.endEditing(for: nil)
        window.makeFirstResponder(self)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if self.isEditingText(in: window) {
                window.endEditing(for: nil)
            }
            window.makeFirstResponder(self)
        }
    }

    /// 播放区滚轮调音量（上大下小）。列表 / 网格上的滚轮原样放过。
    private func handlePlayerVolumeScroll(_ event: NSEvent) -> NSEvent? {
        if isMenuTracking { return event }
        if NSApp.modalWindow != nil { return event }
        guard let window, window.isKeyWindow, window === self.window else { return event }
        if event.window !== window { return event }
        if window is NSPanel { return event }
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return event }
        guard isPlayerVideo(hit) else { return event }
        if abs(event.scrollingDeltaY) < abs(event.scrollingDeltaX) { return event }
        let delta: Double
        if event.hasPreciseScrollingDeltas {
            delta = event.scrollingDeltaY * 0.2
            if abs(delta) < 0.05 { return event }
        } else {
            guard event.scrollingDeltaY != 0 else { return event }
            delta = event.scrollingDeltaY > 0 ? 5 : -5
        }
        env?.playback.adjustVolume(by: delta)
        return nil
    }

    private func isPlayerVideo(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node is MPVGLBackend { return true }
            current = node.superview
        }
        return false
    }

    private func shouldHandle(in window: NSWindow?) -> Bool {
        if isMenuTracking { return false }
        if NSApp.modalWindow != nil { return false }
        guard let window, window.isKeyWindow, window === self.window else { return false }
        if window is NSPanel { return false }
        if isEditingText(in: window) { return false }
        return true
    }

    private func isEditingText(in window: NSWindow) -> Bool {
        let first = window.firstResponder
        return first is NSTextView || first is NSTextField
    }

    private func isClickOnTextInput(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSTextView || current is NSTextField { return true }
            view = current.superview
        }
        return false
    }

    /// 把焦点收回本视图。点过按钮之后控件可能仍占着 first responder，
    /// 这里只在窗口空闲时收回，不在鼠标抬起时抢，以免打断倍速菜单。
    func reclaimKeyFocus() {
        guard !isMenuTracking else { return }
        guard let window, window.isKeyWindow else { return }
        if NSApp.modalWindow != nil { return }
        if isEditingText(in: window) { return }
        if window.firstResponder === self { return }
        window.makeFirstResponder(self)
    }

}

struct ClipFlowInputHost: NSViewRepresentable {
    var env: AppEnvironment

    func makeNSView(context: Context) -> ClipFlowKeyView {
        let view = ClipFlowKeyView()
        view.env = env
        return view
    }

    func updateNSView(_ nsView: ClipFlowKeyView, context: Context) {
        nsView.env = env
    }

    static func dismantleNSView(_ nsView: ClipFlowKeyView, coordinator: ()) {
        nsView.stop()
    }
}

/// 根视图挂上：窗口收键、中键全屏。
struct ClipFlowInputModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.background {
            ClipFlowInputHost(env: env)
        }
    }
}

extension View {
    func clipFlowInput() -> some View {
        modifier(ClipFlowInputModifier())
    }
}
