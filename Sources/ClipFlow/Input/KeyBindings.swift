import AppKit
import SwiftUI

/// README 第 8 节快捷键。焦点在 SwiftUI，不交给 mpv。
enum KeyBindings {

    /// 处理一次按键。`Cmd+W` / `Cmd+S` 不占用，交给系统。
    @MainActor
    static func handle(_ press: KeyPress, env: AppEnvironment) -> KeyPress.Result {
        if press.phase == .up { return .ignored }

        let mods = press.modifiers.intersection([.command, .shift, .option, .control])
        if mods.contains(.option) || mods.contains(.control) {
            return .ignored
        }

        if mods.contains(.command) {
            return handleCommand(press, env: env)
        }

        switch press.key {
        case .space:
            return once(press) { env.playback.togglePlayPause() }
        case .escape:
            env.playback.exitFullscreen()
            return .handled
        case .leftArrow:
            env.playback.seek(by: -5)
            return .handled
        case .rightArrow:
            env.playback.seek(by: 5)
            return .handled
        case .upArrow:
            env.playback.seek(by: -30)
            return .handled
        case .downArrow:
            env.playback.seek(by: 30)
            return .handled
        case .pageUp:
            env.selectOffset(-1, wrap: false)
            return .handled
        case .pageDown:
            env.selectOffset(1, wrap: false)
            return .handled
        case .tab:
            // 交给菜单快捷键，避免这里吞掉后两边各切一次、或谁都切不到。
            return .ignored
        default:
            break
        }

        let ch = press.characters.lowercased()
        switch ch {
        case " ":
            return once(press) { env.playback.togglePlayPause() }
        case "q":
            env.selectOffset(-1, wrap: false)
            return .handled
        case "e":
            env.selectOffset(1, wrap: false)
            return .handled
        case "a":
            env.playback.seek(by: -5)
            return .handled
        case "d":
            env.playback.seek(by: 5)
            return .handled
        case "w":
            env.playback.seek(by: -30)
            return .handled
        case "s":
            env.playback.seek(by: 30)
            return .handled
        case "f":
            return once(press) { env.playback.toggleFullscreen() }
        case "l":
            return once(press) { env.playback.cycleLoopMode() }
        case "m":
            return once(press) { env.playback.toggleMute() }
        case "c":
            return once(press) { env.captureCoverFromCurrentFrame() }
        case "[", "「":
            return once(press) { env.playback.nudgeSpeed(-1) }
        case "]", "」":
            return once(press) { env.playback.nudgeSpeed(1) }
        default:
            return .ignored
        }
    }

    @MainActor
    private static func handleCommand(_ press: KeyPress, env: AppEnvironment) -> KeyPress.Result {
        // Cmd+O 由菜单处理。Cmd+W / Cmd+S 明确不占用。
        switch press.key {
        case .upArrow:
            env.selectOffset(-1, wrap: false)
            return .handled
        case .downArrow:
            env.selectOffset(1, wrap: false)
            return .handled
        default:
            return .ignored
        }
    }

    /// 切换类按键忽略长按重复，但仍吞掉，避免漏到别处。
    private static func once(_ press: KeyPress, _ action: () -> Void) -> KeyPress.Result {
        if press.phase == .down { action() }
        return .handled
    }
}

/// 根视图挂上：可聚焦、收键、中键全屏。
struct ClipFlowInputModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @FocusState private var keysFocused: Bool
    @State private var mouseMonitor: Any?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($keysFocused)
            .onAppear {
                keysFocused = true
                installMouseMonitor()
            }
            .onChange(of: env.selectedID) { _, _ in
                keysFocused = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                keysFocused = true
            }
            .onKeyPress { press in
                KeyBindings.handle(press, env: env)
            }
            .onDisappear { removeMouseMonitor() }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        let playback = env.playback
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 2 else { return event }
            guard event.window?.isKeyWindow == true else { return event }
            playback.toggleFullscreen()
            return nil
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }
}

extension View {
    func clipFlowInput() -> some View {
        modifier(ClipFlowInputModifier())
    }
}
