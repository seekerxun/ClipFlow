import AVFoundation
import Foundation

/// 时长 / 画幅探测。只读元数据，不解码画面。
enum MediaProbe {

    struct Info: Sendable {
        let duration: Double
        /// 已应用旋转矩阵后的显示尺寸。
        let width: Int
        let height: Int

        var isPortrait: Bool { height > width }
    }

    enum ProbeError: Error, Sendable {
        case timedOut
        case noVideoTrack
        case unreadable(String)
    }

    /// - Parameter timeout: 超时保护。NAS 上的老素材可能让 AVAsset 挂很久，
    ///   没有这道闸整个扫描会卡死在一两个文件上。
    static func probe(_ url: URL, timeout: TimeInterval = 5) async throws -> Info {
        do {
            return try await probeWithAVFoundation(url, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // AVFoundation 是硬件加速主路径。只有它明确失败或超时后，才启动 ffprobe。
            return try await FFmpegMediaProbe.probe(url, timeout: timeout)
        }
    }

    private static func probeWithAVFoundation(
        _ url: URL,
        timeout: TimeInterval
    ) async throws -> Info {
        let asset = AVURLAsset(url: url)
        return try await AsyncTimeoutBoundary.run(
            timeout: timeout,
            timeoutError: ProbeError.timedOut,
            onStop: {
                // Task.cancel 对部分网络 / 老容器的 AVAsset load 不足以立即生效；
                // 同时显式取消 asset 的异步加载，ffprobe 才能按时接管。
                asset.cancelLoading()
            },
            operation: {
                try await loadWithAVFoundation(asset)
            }
        )
    }

    private static func loadWithAVFoundation(_ asset: AVURLAsset) async throws -> Info {
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProbeError.unreadable(error.localizedDescription)
        }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError.noVideoTrack
        }

        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)

        // 竖屏素材常常是「横向存储 + 旋转元数据」。不套这个矩阵的话
        // 1080×1920 会被读成 1920×1080，缩略图会横过来。
        let displaySize = naturalSize.applying(transform)
        let width = Int(abs(displaySize.width).rounded())
        let height = Int(abs(displaySize.height).rounded())

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw ProbeError.unreadable("时长无效")
        }
        guard width > 0, height > 0 else {
            throw ProbeError.unreadable("画幅无效")
        }

        return Info(duration: seconds, width: width, height: height)
    }
}

/// 不等待不响应取消的底层异步操作。超时 / 外部取消先安全完成调用方，再让底层任务
/// 持有自己的生命周期并在后台收尾；`onStop` 用于取消 AVAsset 自身的加载。
enum AsyncTimeoutBoundary {

    static func run<T: Sendable>(
        timeout: TimeInterval,
        timeoutError: Error,
        onStop: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let state = State<T>(onStop: onStop)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let task = Task {
                    do {
                        state.finish(.success(try await operation()))
                    } catch {
                        state.finish(.failure(error))
                    }
                }
                state.attach(task)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.stop(with: timeoutError)
                }
            }
        } onCancel: {
            state.stop(with: CancellationError())
        }
    }

    private final class State<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let onStop: @Sendable () -> Void
        private var continuation: CheckedContinuation<T, Error>?
        private var task: Task<Void, Never>?
        private var terminal: Result<T, Error>?

        init(onStop: @escaping @Sendable () -> Void) {
            self.onStop = onStop
        }

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let pending = lock.withLock { () -> Result<T, Error>? in
                if let terminal { return terminal }
                self.continuation = continuation
                return nil
            }
            if let pending { continuation.resume(with: pending) }
        }

        func attach(_ task: Task<Void, Never>) {
            let shouldCancel = lock.withLock {
                if terminal != nil { return true }
                self.task = task
                return false
            }
            if shouldCancel { task.cancel() }
        }

        func finish(_ result: Result<T, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
                guard terminal == nil else { return nil }
                terminal = result
                defer {
                    self.continuation = nil
                    task = nil
                }
                return self.continuation
            }
            continuation?.resume(with: result)
        }

        func stop(with error: Error) {
            let stopped = lock.withLock {
                () -> (CheckedContinuation<T, Error>?, Task<Void, Never>?)? in
                guard terminal == nil else { return nil }
                terminal = .failure(error)
                defer {
                    continuation = nil
                    task = nil
                }
                return (continuation, task)
            }
            guard let stopped else { return }
            onStop()
            stopped.1?.cancel()
            stopped.0?.resume(throwing: error)
        }
    }
}

/// AVFoundation 无法识别容器或编码时的元数据回退。
enum FFmpegMediaProbe {

    private struct Response: Decodable {
        struct Stream: Decodable {
            struct Tags: Decodable { let rotate: String? }
            struct SideData: Decodable { let rotation: Double? }

            let width: Int?
            let height: Int?
            let duration: String?
            let tags: Tags?
            let sideDataList: [SideData]?

            enum CodingKeys: String, CodingKey {
                case width, height, duration, tags
                case sideDataList = "side_data_list"
            }
        }

        struct Format: Decodable { let duration: String? }

        let streams: [Stream]
        let format: Format?
    }

    static func probe(_ url: URL, timeout: TimeInterval = 5) async throws -> MediaProbe.Info {
        let executable = try ProcessRunner.executable(named: "ffprobe")
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries",
                "format=duration:stream=width,height,duration:stream_tags=rotate:stream_side_data=rotation",
                "-of", "json",
                url.path(percentEncoded: false)
            ],
            timeout: timeout
        )
        try Task.checkCancellation()

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: result.stdout)
        } catch {
            throw MediaProbe.ProbeError.unreadable("ffprobe 返回无法解析的元数据")
        }
        guard let stream = response.streams.first,
              let codedWidth = stream.width,
              let codedHeight = stream.height,
              codedWidth > 0,
              codedHeight > 0
        else {
            throw MediaProbe.ProbeError.noVideoTrack
        }

        let duration = [stream.duration, response.format?.duration]
            .compactMap { $0.flatMap(Double.init) }
            .first { $0.isFinite && $0 > 0 }
        guard let duration else {
            throw MediaProbe.ProbeError.unreadable("ffprobe 未返回有效时长")
        }

        let sideDataRotation = stream.sideDataList?
            .compactMap(\.rotation)
            .first
        let tagRotation = stream.tags?.rotate.flatMap(Double.init)
        let rotation = sideDataRotation ?? tagRotation ?? 0
        let display = displaySize(width: codedWidth, height: codedHeight, rotation: rotation)
        guard display.width > 0, display.height > 0 else {
            throw MediaProbe.ProbeError.unreadable("ffprobe 返回的画幅无效")
        }
        return MediaProbe.Info(duration: duration, width: display.width, height: display.height)
    }

    /// ffprobe 返回编码尺寸和旋转角；列表需要的是应用旋转后的包围盒尺寸。
    static func displaySize(width: Int, height: Int, rotation: Double) -> (width: Int, height: Int) {
        let radians = rotation * .pi / 180
        let displayWidth = abs(Double(width) * cos(radians))
            + abs(Double(height) * sin(radians))
        let displayHeight = abs(Double(width) * sin(radians))
            + abs(Double(height) * cos(radians))
        return (Int(displayWidth.rounded()), Int(displayHeight.rounded()))
    }
}
