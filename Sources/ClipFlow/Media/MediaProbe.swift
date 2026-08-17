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
        try await withThrowingTaskGroup(of: Info.self) { group in
            group.addTask {
                try await load(url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProbeError.timedOut
            }
            guard let first = try await group.next() else {
                throw ProbeError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private static func load(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
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
