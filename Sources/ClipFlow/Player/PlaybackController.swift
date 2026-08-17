import AppKit
import Foundation
import Observation

/// 循环模式。单个循环由控制器自己处理；列表循环和自动下一个靠 `onPlaybackEnded`
/// 通知上层，由界面换选中项。不用 mpv 的 playlist。
enum LoopMode: Int, CaseIterable, Sendable {
    /// 播完停在最后一帧（keep-open），仍通知上层，由界面决定是否自动下一个。
    case off
    /// 当前文件循环。
    case single
    /// 列表循环：通知上层换下一项，播到末尾再回到第一项。
    case playlist
}

/// 播放状态机。单实例 + `loadfile`，不预载。
///
/// 只依赖 `MPVRenderBackend` 抽象，不碰 OpenGL 实现。
@Observable
final class PlaybackController {

    // MARK: - 给界面的状态

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused: Bool = true
    private(set) var isMuted: Bool = false
    private(set) var volume: Double = 100
    private(set) var speed: Double = 1
    private(set) var loopMode: LoopMode = .off
    private(set) var isLoaded: Bool = false
    private(set) var isFullscreen: Bool = false

    /// 当前文件自然播完。单个循环不会走到这里。
    /// 上层根据 `loopMode` 决定：列表循环则换下一项（末尾回到第一项）；
    /// 关闭则也可自动下一个，但不回头。
    @ObservationIgnored var onPlaybackEnded: (() -> Void)?

    // MARK: - 内部

    @ObservationIgnored private let mpv = MPVClient()
    @ObservationIgnored private weak var backend: MPVRenderBackend?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var isRenderReady = false
    @ObservationIgnored private var fullscreenObservers: [NSObjectProtocol] = []

    init() {
        guard mpv.create() else { return }

        mpv.setOption("vo", "libmpv")
        mpv.setOption("idle", "yes")
        mpv.setOption("keep-open", "yes")
        mpv.setOption("hr-seek", "yes")
        mpv.setOption("cache", "yes")
        mpv.setOption("hwdec", "auto-safe")
        mpv.setOption("osc", "no")
        mpv.setOption("input-default-bindings", "no")
        mpv.setOption("input-vo-keyboard", "no")
        mpv.setOption("terminal", "no")
        mpv.setOption("osd-level", "0")

        guard mpv.initialize() else { return }

        wireCallbacks()
        observeFullscreen()
    }

    deinit {
        fullscreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        backend?.detach()
        mpv.shutdown()
    }

    /// 由 `MPVVideoView` 在创建宿主视图时调用。只接收抽象后端。
    func attachRenderBackend(_ backend: MPVRenderBackend) {
        if let old = self.backend, old !== backend {
            old.detach()
        }
        self.backend = backend
        isRenderReady = false
        backend.onRenderContextReady = { [weak self] in
            self?.handleRenderContextReady()
        }
        if let handle = mpv.rawHandle {
            backend.attach(mpvHandle: handle)
        }
    }

    func shutdown() {
        backend?.detach()
        backend = nil
        isRenderReady = false
        mpv.shutdown()
    }

    // MARK: - 加载 / 播放

    func loadFile(_ url: URL) {
        pendingURL = url
        guard isRenderReady else { return }
        pendingURL = nil
        isLoaded = false
        currentTime = 0
        duration = 0
        mpv.loadFile(url.path(percentEncoded: false))
        mpv.setFlag("pause", false)
        isPaused = false
    }

    func play() {
        mpv.setFlag("pause", false)
        isPaused = false
    }

    func pause() {
        mpv.setFlag("pause", true)
        isPaused = true
    }

    func togglePlayPause() {
        if isPaused { play() } else { pause() }
    }

    func seek(to seconds: Double) {
        mpv.seek(absolute: seconds)
    }

    func seek(by seconds: Double) {
        mpv.seek(relative: seconds)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 100)
        volume = clamped
        mpv.setDouble("volume", clamped)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        mpv.setFlag("mute", muted)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setSpeed(_ value: Double) {
        let clamped = min(max(value, 0.25), 4)
        speed = clamped
        mpv.setDouble("speed", clamped)
    }

    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        mpv.setString("loop-file", mode == .single ? "inf" : "no")
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// 给 C 键抽封面用：直接问 mpv 当前时间，绕开属性事件的推送延迟。
    /// C 键本身本块不做。
    func currentPlaybackTime() -> Double? {
        mpv.double("time-pos")
    }

    // MARK: - 内部

    private func handleRenderContextReady() {
        guard !isRenderReady else { return }
        isRenderReady = true
        if let pendingURL {
            loadFile(pendingURL)
        }
    }

    private func wireCallbacks() {
        mpv.onPropertyChange = { [weak self] name, value in
            guard let self else { return }
            switch (name, value) {
            case ("time-pos", .double(let v)): currentTime = v
            case ("duration", .double(let v)): duration = v
            case ("pause", .flag(let v)): isPaused = v
            case ("mute", .flag(let v)): isMuted = v
            case ("volume", .double(let v)): volume = v
            case ("speed", .double(let v)): speed = v
            default: break
            }
        }

        mpv.onFileLoaded = { [weak self] in
            self?.isLoaded = true
        }

        mpv.onEndFile = { [weak self] in
            guard let self else { return }
            if loopMode == .single {
                seek(to: 0)
                play()
                return
            }
            onPlaybackEnded?()
        }
    }

    private func observeFullscreen() {
        let center = NotificationCenter.default
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isFullscreen = true
        })
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isFullscreen = false
        })
    }
}
