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
            env.playback.seek(by: -5)
            return true
        case 124: // right
            env.playback.seek(by: 5)
            return true
        case 126: // up
            env.playback.seek(by: -30)
            return true
        case 125: // down
            env.playback.seek(by: 30)
            return true
        case 116: // pageUp
            env.selectOffset(-1, wrap: false)
            return true
        case 121: // pageDown
            env.selectOffset(1, wrap: false)
            return true
        case 48: // tab：显示 / 隐藏素材浏览区，不交给系统切焦点
            return once(event) { env.isBrowserVisible.toggle() }
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
            env.playback.seek(by: -5)
            return true
        case "d":
            env.playback.seek(by: 5)
            return true
        case "w":
            env.playback.seek(by: -30)
            return true
        case "s":
            env.playback.seek(by: 30)
            return true
        case "f":
            return once(event) { env.playback.toggleFullscreen() }
        case "l":
            return once(event) { env.playback.cycleLoopMode() }
        case "m":
            return once(event) { env.playback.toggleMute() }
        case "c":
            return once(event) { env.captureCoverFromCurrentFrame() }
        case "[", "「":
            return once(event) { env.playback.nudgeSpeed(-1) }
        case "]", "」":
            return once(event) { env.playback.nudgeSpeed(1) }
        default:
            return false
        }
    }

    @MainActor
    private static func handleCommand(_ event: NSEvent, env: AppEnvironment) -> Bool {
        switch event.keyCode {
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

        if let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            guard let self else { return event }
            guard event.buttonNumber == 2 else { return event }
            guard self.shouldHandle(in: event.window) else { return event }
            self.env?.playback.toggleFullscreen()
            return nil
        }) {
            monitors.append(mouseMonitor)
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
        guard shouldHandle(in: event.window) else { return false }
        guard let env else { return false }
        return KeyBindings.handle(event, env: env)
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
