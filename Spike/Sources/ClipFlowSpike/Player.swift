import AppKit
import Foundation
import Observation

@Observable
final class Player {

    // MARK: - 对 UI 暴露的状态

    var isAttached = false
    var isPaused = true
    var timePos: Double = 0
    var duration: Double = 0
    var mediaInfo = "尚未加载"
    var status = "等待挂载 mpv…"
    var logTail: [String] = []

    // MARK: - 内部

    @ObservationIgnored private let mpv = MPVClient()
    @ObservationIgnored private var pendingFile: String?
    @ObservationIgnored private(set) var didLoadFile = false

    init(initialFile: String?) {
        pendingFile = initialFile
    }

    /// 由 `MPVContainerView` 在进入窗口层级后调用一次。
    /// 顺序不能变：create → 设选项 → 设 wid → initialize → loadfile。
    func attach(to view: MPVContainerView) {
        guard !isAttached else { return }

        guard mpv.create() else {
            status = "mpv_create() 失败"
            return
        }

        // 只能在 initialize 之前设的选项
        mpv.setOption("terminal", "no")
        mpv.setOption("input-default-bindings", "no")   // 键盘由 SwiftUI 接管
        mpv.setOption("input-vo-keyboard", "no")
        mpv.setOption("osc", "no")                      // 不要 mpv 自带的控制条
        mpv.setOption("osd-level", "0")
        mpv.setOption("idle", "yes")                    // 播完不退出实例
        mpv.setOption("keep-open", "yes")               // 播完停在最后一帧
        mpv.setOption("hr-seek", "yes")                 // 精确 seek
        mpv.setOption("force-window", "yes")            // 未加载时也铺一层黑底
        mpv.setOption("hwdec", "auto-safe")

        mpv.setParentView(view)

        guard mpv.initialize() else {
            status = "mpv_initialize() 失败"
            return
        }

        wireCallbacks()
        isAttached = true
        status = "mpv 已挂载（--wid）"

        if let pendingFile {
            self.pendingFile = nil
            load(pendingFile)
        }
    }

    private func wireCallbacks() {
        mpv.onPropertyChange = { [weak self] name, value in
            guard let self else { return }
            switch (name, value) {
            case ("time-pos", .double(let v)): timePos = v
            case ("duration", .double(let v)): duration = v
            case ("pause", .flag(let v)): isPaused = v
            default: break
            }
        }

        mpv.onFileLoaded = { [weak self] in
            guard let self else { return }
            didLoadFile = true
            let codec = mpv.string("video-codec") ?? "?"
            let w = mpv.string("width") ?? "?"
            let h = mpv.string("height") ?? "?"
            let fps = mpv.string("container-fps") ?? "?"
            let format = mpv.string("file-format") ?? "?"
            mediaInfo = "\(format) · \(codec) · \(w)×\(h) · \(fps) fps"
            status = "已加载"
        }

        mpv.onEndFile = { [weak self] in
            self?.status = "播放结束（keep-open 保持在最后一帧）"
        }

        mpv.onLog = { [weak self] line in
            guard let self else { return }
            logTail.append(line)
            if logTail.count > 12 { logTail.removeFirst(logTail.count - 12) }
        }
    }

    // MARK: - 操作

    func load(_ path: String) {
        guard isAttached else {
            pendingFile = path
            return
        }
        didLoadFile = false
        duration = 0
        timePos = 0
        status = "加载中…"
        mpv.loadFile(path)
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        mpv.setFlag("pause", paused)
        isPaused = paused
    }

    func seek(relative seconds: Double) { mpv.seek(relative: seconds) }

    func seek(absolute seconds: Double) { mpv.seek(absolute: seconds) }

    func screenshot(to path: String) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        mpv.screenshot(to: path)
    }

    /// 直接问 mpv 要当前时间，绕开属性事件的推送延迟。自测里用它判定。
    func currentTimeFromMPV() -> Double? { mpv.double("time-pos") }

    func shutdown() { mpv.shutdown() }
}
