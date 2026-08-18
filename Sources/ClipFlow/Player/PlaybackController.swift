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

    var title: String {
        switch self {
        case .off: return "关闭循环"
        case .single: return "单个循环"
        case .playlist: return "列表循环"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "repeat"
        case .single: return "repeat.1"
        case .playlist: return "repeat"
        }
    }
}

/// 播放状态机。单实例 + `loadfile`，不预载。
///
/// 只依赖 `MPVRenderBackend` 抽象，不碰 OpenGL 实现。
@Observable
final class PlaybackController {

    private enum Pref {
        static let volume = "playbackVolume"
        static let loopMode = "playbackLoopMode"
    }

    // MARK: - 给界面的状态

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused: Bool = true
    private(set) var isMuted: Bool = false
    private(set) var volume: Double = 100
    private(set) var speed: Double = 1
    private(set) var loopMode: LoopMode = .off
    /// 片段循环起点。只按当前播放时间设，不跟进度条点击走。
    private(set) var loopA: Double?
    /// 片段循环终点。
    private(set) var loopB: Double?
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
    @ObservationIgnored private var abSeekPending = false

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Pref.volume) != nil {
            volume = min(max(defaults.double(forKey: Pref.volume), 0), 100)
        }
        if defaults.object(forKey: Pref.loopMode) != nil,
           let savedLoopMode = LoopMode(rawValue: defaults.integer(forKey: Pref.loopMode))
        {
            loopMode = savedLoopMode
        }

        startEngine()
    }

    deinit {
        shutdown()
    }

    /// 建一份 libmpv 实例并接上回调。已经有实例就当作已经成功。
    ///
    /// 这段本来直接写在 `init` 里。拆出来是因为播放实例必须能重建：窗口关闭
    /// 通知会在启动期误报一次（见 `shutdown()` 的注释），实例被拆掉之后
    /// 得能原地长回来，不能一次误报就让这扇窗口永远放不了片。
    @discardableResult
    private func startEngine() -> Bool {
        if mpv.rawHandle != nil { return true }
        guard mpv.create() else { return false }

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

        guard mpv.initialize() else {
            // 半成品句柄不能留着：留着的话 `rawHandle != nil` 会一直挡住重建。
            mpv.shutdown()
            return false
        }

        wireCallbacks()
        if fullscreenObservers.isEmpty {
            observeFullscreen()
        }
        // 重建出来的实例是全新的，界面上已有的音量 / 静音 / 倍速要重新交代一遍。
        mpv.setDouble("volume", volume)
        mpv.setFlag("mute", isMuted)
        mpv.setDouble("speed", speed)
        applyLoopFileOption()
        return true
    }

    /// 由 `MPVVideoView` 在创建宿主视图时调用。只接收抽象后端。
    func attachRenderBackend(_ backend: MPVRenderBackend) {
        // 已经挂好并且就绪的话就别再来一遍：界面每次刷新都会调用这里。
        if self.backend === backend, isRenderReady { return }
        if let old = self.backend, old !== backend {
            old.detach()
        }
        self.backend = backend
        isRenderReady = false
        backend.onRenderContextReady = { [weak self] in
            self?.handleRenderContextReady()
        }
        startEngine()
        if let handle = mpv.rawHandle {
            backend.attach(mpvHandle: handle)
        }
    }

    /// 拆掉渲染上下文和 libmpv 实例。可以重复调用，也可以被后面的重建撤销。
    ///
    /// 这里刻意不做成一次性的。SwiftUI 在启动期会把窗口连同视图树拆一次再建
    /// 回来，AppKit 为那扇短命的窗口发的是货真价实的关闭通知，光看通知分不出
    /// 「用户关窗」和「框架重建」。做成一次性的话，那一次误报就会把这扇窗口的
    /// 播放实例永久判死。真正的关窗由对象析构兜底，误报则由随后的重新挂载修好。
    func shutdown() {
        // render context 必须先于 libmpv 句柄销毁；否则后端仍可能访问已释放句柄。
        backend?.detach()
        isRenderReady = false
        isLoaded = false
        mpv.shutdown()
        fullscreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullscreenObservers.removeAll()
    }

    /// 待播文件还在队列里，但底下的实例被拆过。就地重建一份并重新挂回画面。
    private func recoverEngineIfNeeded() {
        guard mpv.rawHandle == nil, let backend else { return }
        guard startEngine(), let handle = mpv.rawHandle else { return }
        isRenderReady = false
        backend.onRenderContextReady = { [weak self] in
            self?.handleRenderContextReady()
        }
        backend.attach(mpvHandle: handle)
    }

    // MARK: - 加载 / 播放

    func loadFile(_ url: URL) {
        pendingURL = url
        if !isRenderReady {
            recoverEngineIfNeeded()
            // 重建过程中就绪的话，待播队列已经把这条播掉了，不必再来一次。
            guard pendingURL != nil else { return }
        }
        guard isRenderReady else { return }
        pendingURL = nil
        isLoaded = false
        currentTime = 0
        duration = 0
        clearABLoop()
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
        UserDefaults.standard.set(clamped, forKey: Pref.volume)
        mpv.setDouble("volume", clamped)
    }

    /// 滚轮调音量。往上加大；从静音往上滚会取消静音。
    func adjustVolume(by delta: Double) {
        let next = min(max(volume + delta, 0), 100)
        setVolume(next)
        if isMuted && next > 0 {
            setMuted(false)
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        mpv.setFlag("mute", muted)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    static let speedSteps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    /// `Z`：0.75 → 0.5 → 0.25 → 1 → 0.75 …
    static let slowSpeedCycle: [Double] = [0.75, 0.5, 0.25, 1]
    /// `C`：1.25 → 1.5 → 2 → 1 → 1.25 …
    static let fastSpeedCycle: [Double] = [1.25, 1.5, 2, 1]

    func setSpeed(_ value: Double) {
        let clamped = min(max(value, 0.25), 4)
        speed = clamped
        mpv.setDouble("speed", clamped)
    }

    func cycleSlowSpeed() {
        cycleSpeed(through: Self.slowSpeedCycle, fallback: 0.75)
    }

    func cycleFastSpeed() {
        cycleSpeed(through: Self.fastSpeedCycle, fallback: 1.25)
    }

    func resetSpeed() {
        setSpeed(1)
    }

    private func cycleSpeed(through steps: [Double], fallback: Double) {
        if let index = steps.firstIndex(where: { abs($0 - speed) < 0.01 }) {
            setSpeed(steps[(index + 1) % steps.count])
        } else {
            setSpeed(fallback)
        }
    }

    static func nearestSpeed(_ value: Double) -> Double {
        speedSteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    static func speedLabel(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.01 {
            return String(format: "%.0f×", value.rounded())
        }
        return String(format: "%g×", value)
    }

    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Pref.loopMode)
        applyLoopFileOption()
    }

    func cycleLoopMode() {
        let all = LoopMode.allCases
        let index = all.firstIndex(of: loopMode) ?? 0
        setLoopMode(all[(index + 1) % all.count])
    }

    /// 两端都齐且起点早于终点才循环。只齐一端不循环。
    var isABLoopActive: Bool {
        guard let a = loopA, let b = loopB else { return false }
        return a < b
    }

    func markLoopA() {
        guard let t = clampedLoopTime() else { return }
        loopA = t
        normalizeLoopPoints()
        applyLoopFileOption()
    }

    func markLoopB() {
        guard let t = clampedLoopTime() else { return }
        loopB = t
        normalizeLoopPoints()
        applyLoopFileOption()
    }

    func clearLoopA() {
        loopA = nil
        abSeekPending = false
        applyLoopFileOption()
    }

    func clearLoopB() {
        loopB = nil
        abSeekPending = false
        applyLoopFileOption()
    }

    private func clearABLoop() {
        loopA = nil
        loopB = nil
        abSeekPending = false
        applyLoopFileOption()
    }

    /// 有 A-B 时由我们自己 seek 回 A，不要让 mpv 的单文件循环抢先绕回 0。
    private func applyLoopFileOption() {
        mpv.setString("loop-file", loopMode == .single && !isABLoopActive ? "inf" : "no")
    }

    private func clampedLoopTime() -> Double? {
        guard isLoaded else { return nil }
        var t = currentPlaybackTime() ?? currentTime
        guard t.isFinite, t >= 0 else { return nil }
        if duration > 0 {
            t = min(t, duration)
        }
        return t
    }

    /// 终点早于起点则对调。
    private func normalizeLoopPoints() {
        guard let a = loopA, let b = loopB, b < a else { return }
        loopA = b
        loopB = a
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func exitFullscreen() {
        guard isFullscreen else { return }
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// 给 B 键抽封面用：直接问 mpv 当前时间，绕开属性事件的推送延迟。
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
            case ("time-pos", .double(let v)):
                currentTime = v
                enforceABLoop(at: v)
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
            if isABLoopActive, let a = loopA {
                abSeekPending = true
                seek(to: a)
                play()
                return
            }
            if loopMode == .single {
                seek(to: 0)
                play()
                return
            }
            onPlaybackEnded?()
        }
    }

    /// 有 A-B 时播到 B 就回到 A，不通知上层切下一条。
    private func enforceABLoop(at time: Double) {
        guard isABLoopActive, let a = loopA, let b = loopB else { return }
        if isPaused { return }
        if abSeekPending {
            if time < b { abSeekPending = false }
            return
        }
        guard time >= b else { return }
        abSeekPending = true
        seek(to: a)
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
