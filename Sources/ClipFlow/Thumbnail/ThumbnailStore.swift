import Foundation

/// 预览图的磁盘缓存。
///
/// 图片放缓存目录（系统可回收，丢了自动重建），索引放应用支持目录
/// （重建成本高，不希望被系统清掉）。因此可能出现「有索引但图没了」的情况，
/// 读取方必须能接受这一点并触发重建。
enum ThumbnailStore {

    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: "ClipFlow", directoryHint: .isDirectory)
    }()

    static var spriteDirectory: URL {
        root.appending(path: "sprites", directoryHint: .isDirectory)
    }

    static var coverDirectory: URL {
        root.appending(path: "covers", directoryHint: .isDirectory)
    }

    static func spriteURL(digest: String) -> URL {
        spriteDirectory.appending(path: "\(digest).jpg", directoryHint: .notDirectory)
    }

    static func coverURL(digest: String) -> URL {
        coverDirectory.appending(path: "\(digest).jpg", directoryHint: .notDirectory)
    }

    static func prepareDirectories() throws {
        for directory in [spriteDirectory, coverDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
    }

    static func hasCover(digest: String) -> Bool {
        FileManager.default.fileExists(
            atPath: coverURL(digest: digest).path(percentEncoded: false)
        )
    }

    static func hasSprite(digest: String) -> Bool {
        FileManager.default.fileExists(
            atPath: spriteURL(digest: digest).path(percentEncoded: false)
        )
    }

    static func writeCover(_ data: Data, digest: String) throws {
        try data.write(to: coverURL(digest: digest), options: .atomic)
    }

    static func writeSprite(_ data: Data, digest: String) throws {
        try data.write(to: spriteURL(digest: digest), options: .atomic)
    }

    /// 当前占用的磁盘空间，用于设置里展示和清理。
    static func diskUsage() -> Int64 {
        var total: Int64 = 0
        for directory in [spriteDirectory, coverDirectory] {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for entry in entries {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }
}
