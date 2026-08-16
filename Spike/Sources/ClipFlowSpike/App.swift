import AppKit
import SwiftUI

enum SpikeConfig {
    static var isSelfTest: Bool {
        ProcessInfo.processInfo.environment["CLIPFLOW_SELFTEST"] == "1"
    }

    static var outDir: String {
        FileManager.default.currentDirectoryPath + "/out"
    }

    /// 命令行第一个非选项参数当作要播的文件，缺省用同目录的 sample.mkv。
    static var initialFile: String? {
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return URL(fileURLWithPath: arg).standardizedFileURL.path
        }
        let fallback = FileManager.default.currentDirectoryPath + "/sample.mkv"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // SPM 可执行文件没有 .app bundle，必须手动提成 regular 才能拿到焦点和菜单栏
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // SPM 可执行文件没有 bundle，也就没有 Resources / CFBundleIconFile，
        // Dock 只会给一个系统默认占位图标。运行时直接塞一张图是唯一的办法。
        // 正式的 .icns 要等 V1 建 Xcode 工程、有了 .app bundle 之后。
        // 优先用 Tools/make-icon.swift 抠过透明的版本；源 icon.png 没有 alpha，
        // 圆角外面是纯黑，直接用会在 Dock 里显示成黑方块。
        for candidate in ["../Tools/out/icon-1024.png", "../icon.png", "icon.png"] {
            if let image = NSImage(contentsOfFile: candidate) {
                NSApp.applicationIconImage = image
                break
            }
        }

        // 打印窗口号，方便外部用 screencapture -l <n> 抓这个窗口做 z-order 验证
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            setvbuf(stdout, nil, _IONBF, 0)
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            print("WINDOW_NUMBER=\(window.windowNumber)")

            // 几何是 --wid 路线的败因，这里留个自动缩放的钩子来验证 render API
            // 是否跟得住窗口尺寸变化。用法：CLIPFLOW_RESIZE=700x500
            guard let spec = ProcessInfo.processInfo.environment["CLIPFLOW_RESIZE"] else { return }
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                var frame = window.frame
                frame.size = NSSize(width: parts[0], height: parts[1])
                window.setFrame(frame, display: true, animate: false)
                print("RESIZED=\(Int(parts[0]))x\(Int(parts[1]))")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct ClipFlowSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var player = Player(initialFile: SpikeConfig.initialFile)

    var body: some Scene {
        Window("ClipFlow V0 Spike", id: "main") {
            SpikeView(player: player)
                .task {
                    guard SpikeConfig.isSelfTest else { return }
                    await SelfTest.run(player: player, outDir: SpikeConfig.outDir)
                }
        }
        .defaultSize(width: 1180, height: 780)
    }
}

// MARK: - 界面

struct SpikeView: View {
    @Bindable var player: Player
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MPVVideoView(player: player)

                // ── z-order 测试层 ──────────────────────────────
                // 这些都是 SwiftUI 内容，必须稳定地压在 mpv 的 CALayer 之上。
                // 如果出现闪烁、被盖住、或者拖动窗口时错位，说明 --wid 路线
                // 在浮层上有问题，需要考虑改走 render API + CAMetalLayer。
                hud
                    .padding(12)

                Rectangle()
                    .fill(.red.opacity(0.28))
                    .frame(width: 130, height: 130)
                    .overlay(Text("浮层测试").font(.caption.bold()).foregroundStyle(.white))
                    .padding(.trailing, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            transport
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { player.togglePause(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(relative: -5); return .handled }
        .onKeyPress(.rightArrow) { player.seek(relative: 5); return .handled }
        .onKeyPress(.upArrow) { player.seek(relative: -30); return .handled }
        .onKeyPress(.downArrow) { player.seek(relative: 30); return .handled }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.status)
                .font(.headline)
            Text(player.mediaInfo)
                .font(.system(.caption, design: .monospaced))
            Text("\(timeString(player.timePos)) / \(timeString(player.duration))")
                .font(.system(.caption, design: .monospaced))
            if !player.logTail.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(Array(player.logTail.suffix(6).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { player.timePos },
                    set: { player.seek(absolute: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .disabled(player.duration <= 0)

            HStack(spacing: 12) {
                Button(player.isPaused ? "播放" : "暂停") { player.togglePause() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("−5s") { player.seek(relative: -5) }
                Button("+5s") { player.seek(relative: 5) }
                Divider().frame(height: 16)
                Button("抓一帧") {
                    player.screenshot(to: SpikeConfig.outDir + "/manual-frame.png")
                }
                Button("打开文件…") { openFile() }
                Spacer()
                Text(player.isPaused ? "已暂停" : "播放中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // 不按扩展名过滤——交给 libmpv 去试
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            player.load(url.path)
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
