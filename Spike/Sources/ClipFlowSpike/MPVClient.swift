import CMPV
import Foundation

/// libmpv C API 的薄封装。V0 只做到够验证「能播、能停、能 seek」。
///
/// 生命周期约定：先 `create()` → 设置初始化前才允许设的选项（含 `wid`）
/// → `initialize()` → `loadFile()`。顺序不能变。
final class MPVClient {

    private var handle: OpaquePointer?

    /// 事件回调，全部保证在主线程调用。
    var onFileLoaded: (() -> Void)?
    var onEndFile: (() -> Void)?
    var onPropertyChange: ((String, MPVValue) -> Void)?
    var onLog: ((String) -> Void)?

    enum MPVValue {
        case double(Double)
        case flag(Bool)
    }

    // MARK: - 生命周期

    func create() -> Bool {
        handle = mpv_create()
        return handle != nil
    }

    /// 必须在 `initialize()` 之前调用。
    ///
    /// mpv 会把画面渲染进这个 NSView。传的是裸指针，因此调用方必须保证
    /// 该 view 的生命周期长于 mpv 实例。
    func setParentView(_ view: NSViewLike) {
        var wid = Int64(Int(bitPattern: view.rawPointer))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
    }

    func setOption(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    func initialize() -> Bool {
        guard mpv_initialize(handle) >= 0 else { return false }

        mpv_request_log_messages(handle, "info")

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)

        // mpv 从自己的线程调用这个回调，必须转回主线程再取事件
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

    // MARK: - 命令

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard handle != nil else { return -1 }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(p) } }

        return cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(
                to: UnsafePointer<CChar>?.self, capacity: buf.count
            ) { mpv_command(handle, $0) }
        }
    }

    func loadFile(_ path: String) {
        command(["loadfile", path])
    }

    func seek(relative seconds: Double) {
        command(["seek", String(seconds), "relative"])
    }

    func seek(absolute seconds: Double) {
        command(["seek", String(seconds), "absolute"])
    }

    /// 把当前解码出的画面写成 PNG。`video` 模式不含 OSD / 字幕。
    /// V0 用它来证明解码链路真的通了。
    func screenshot(to path: String) {
        command(["screenshot-to-file", path, "video"])
    }

    // MARK: - 属性

    func setFlag(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

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

    func string(_ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
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
            onEndFile?()

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

        case MPV_EVENT_LOG_MESSAGE:
            guard let raw = ev.pointee.data else { return }
            let msg = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            guard let prefix = msg.prefix, let text = msg.text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                onLog?("[\(String(cString: prefix))] \(line)")
            }

        default:
            break
        }
    }
}

/// 只为了把 AppKit 依赖挡在 MPVClient 外面——它只需要一个裸指针。
protocol NSViewLike: AnyObject {
    var rawPointer: UnsafeMutableRawPointer { get }
}
