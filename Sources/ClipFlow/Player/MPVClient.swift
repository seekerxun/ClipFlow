import Foundation

/// libmpv C API 的薄封装。
///
/// 命令一律走 `mpv_command_async`。用 render API 时，从主线程发同步的
/// `mpv_command` 会把主线程卡住：命令等 VO 出帧，出帧又要主线程去调
/// `mpv_render_context_render`。不要留例外。
final class MPVClient {

    private var handle: OpaquePointer?

    /// 事件回调全部保证在主线程。
    var onFileLoaded: (() -> Void)?
    /// 当前文件自然结束（播完或出错）。`loadfile` 替换当前文件触发的 STOP 不会走到这里。
    var onEndFile: (() -> Void)?
    var onPropertyChange: ((String, MPVValue) -> Void)?

    enum MPVValue {
        case double(Double)
        case flag(Bool)
    }

    /// 供渲染后端建立 `mpv_render_context`。
    var rawHandle: OpaquePointer? { handle }

    // MARK: - 生命周期

    func create() -> Bool {
        handle = mpv_create()
        return handle != nil
    }

    func setOption(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    func initialize() -> Bool {
        guard let handle, mpv_initialize(handle) >= 0 else { return false }

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("mute", MPV_FORMAT_FLAG)
        observe("volume", MPV_FORMAT_DOUBLE)
        observe("speed", MPV_FORMAT_DOUBLE)
        observe("container-fps", MPV_FORMAT_DOUBLE)

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let client = Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { client.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())

        return true
    }

    func shutdown() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
        self.handle = nil
    }

    // MARK: - 命令（全部 async）

    /// 一律 `mpv_command_async`，见类型注释。
    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(p) } }

        return cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(
                to: UnsafePointer<CChar>?.self, capacity: buf.count
            ) { mpv_command_async(handle, 0, $0) }
        }
    }

    func loadFile(_ path: String) {
        command(["loadfile", path])
    }

    func seek(relative seconds: Double, exact: Bool = false) {
        command(["seek", String(seconds), exact ? "relative+exact" : "relative"])
    }

    func seek(absolute seconds: Double, exact: Bool = false) {
        command(["seek", String(seconds), exact ? "absolute+exact" : "absolute"])
    }

    /// 前进一帧。mpv 会顺手把播放停下来。
    func frameStep() {
        command(["frame-step"])
    }

    /// 后退一帧。内部靠精确定位实现，比前进慢，个别文件可能差一帧。
    func frameBackStep() {
        command(["frame-back-step"])
    }

    /// 写属性也走 async 命令，避免同步 `mpv_set_property` 踩到同一类互等。
    func setFlag(_ name: String, _ value: Bool) {
        command(["set", name, value ? "yes" : "no"])
    }

    func setDouble(_ name: String, _ value: Double) {
        command(["set", name, String(value)])
    }

    func setString(_ name: String, _ value: String) {
        command(["set", name, value])
    }

    // MARK: - 读属性

    func flag(_ name: String) -> Bool {
        var v: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 else { return false }
        return v != 0
    }

    func double(_ name: String) -> Double? {
        var v: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 else { return nil }
        return v
    }

    private func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    // MARK: - 事件

    private func drainEvents() {
        guard handle != nil else { return }
        while true {
            guard let ev = mpv_wait_event(handle, 0) else { return }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            dispatch(ev, id)
            if id == MPV_EVENT_SHUTDOWN { return }
        }
    }

    private func dispatch(_ ev: UnsafeMutablePointer<mpv_event>, _ id: mpv_event_id) {
        switch id {
        case MPV_EVENT_FILE_LOADED:
            onFileLoaded?()

        case MPV_EVENT_END_FILE:
            var reason: mpv_end_file_reason = MPV_END_FILE_REASON_EOF
            if let raw = ev.pointee.data {
                reason = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
            }
            // STOP 是 loadfile 替换当前文件，不是播完。
            if reason == MPV_END_FILE_REASON_EOF || reason == MPV_END_FILE_REASON_ERROR {
                onEndFile?()
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = ev.pointee.data else { return }
            let prop = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let namePtr = prop.name, let data = prop.data else { return }
            let name = String(cString: namePtr)
            switch prop.format {
            case MPV_FORMAT_DOUBLE:
                onPropertyChange?(name, .double(data.assumingMemoryBound(to: Double.self).pointee))
            case MPV_FORMAT_FLAG:
                onPropertyChange?(name, .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0))
            default:
                break
            }

        default:
            break
        }
    }
}
