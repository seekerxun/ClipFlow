import Foundation

/// 单个文件的逐帧时间表：每一帧的显示时间。
///
/// 帧号不能用「平均帧率 × 当前时间」算。不少素材是变帧率的——比如 24fps 的
/// 内容存在 60fps 的时间轴上，帧间隔在 0.033s 和 0.05s 之间交替——乘出来的
/// 帧号会时不时跳一格或者卡住不动。这里用 ffprobe 把时间戳整表读出来，
/// 逐帧模式下的帧号、进度条刻度和跳转都以它为准。
///
/// 只读封装里的时间戳，不解码画面，几万帧也就一两秒。
struct FrameTimeline: Sendable {

    /// 每一帧的显示时间，升序，已对齐到播放器的零点。
    let times: [Double]

    var count: Int { times.count }

    /// 这个时间画面上停的是第几帧：最后一个不晚于它的帧。
    func index(at time: Double) -> Int {
        guard !times.isEmpty else { return 0 }
        // 播放器报的时间和表里的是同一批数，留一点余量吸收浮点误差。
        let target = time + 1e-4
        var low = 0
        var high = times.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= target {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// 跳到第几帧时用的定位时间。
    ///
    /// 播放器精确定位后停在「第一个不早于目标时间的帧」上，所以目标要落在
    /// 上一帧和这一帧的中间：正好踩在这一帧的时间上，浮点误差会让它多走一帧。
    func seekTime(forFrame index: Int) -> Double {
        guard !times.isEmpty else { return 0 }
        let i = min(max(index, 0), times.count - 1)
        guard i > 0 else { return times[0] }
        return (times[i - 1] + times[i]) / 2
    }

    enum TimelineError: Error, Sendable {
        case noTimestamps
    }

    static func load(_ url: URL, timeout: TimeInterval = 30) async throws -> FrameTimeline {
        let ffprobe = try ProcessRunner.executable(named: "ffprobe")
        let output = try await ProcessRunner.run(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                // 读包不解码。`format` 段一起要，用来对齐零点。
                "-show_entries", "format=start_time:packet=pts_time",
                "-of", "csv",
                url.path(percentEncoded: false)
            ],
            timeout: timeout
        )
        try Task.checkCancellation()
        return try parse(String(decoding: output.stdout, as: UTF8.self))
    }

    /// ffprobe 的 csv 每行前面带段名：`packet,0.050000` / `format,0.000000`。
    static func parse(_ text: String) throws -> FrameTimeline {
        var times: [Double] = []
        var startTime: Double = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let value = Double(fields[1].trimmingCharacters(in: .whitespaces))
            switch fields[0] {
            case "packet":
                if let value { times.append(value) }
            case "format":
                if let value, value > 0 { startTime = value }
            default:
                break
            }
        }
        guard times.count > 1 else { throw TimelineError.noTimestamps }
        // 包是解码顺序，有 B 帧时不是按显示时间排的。
        times.sort()
        // 播放器把时间轴挪到从 0 起算，这里跟着挪，两边的时间才对得上。
        if startTime > 0 {
            times = times.map { max($0 - startTime, 0) }
        }
        return FrameTimeline(times: times)
    }
}
