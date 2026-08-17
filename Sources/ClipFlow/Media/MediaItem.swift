import CryptoKit
import Foundation

/// 缓存键：路径 + 文件大小 + 修改时间。任一变化即认为是不同的文件，缓存作废重建。
///
/// 不用内容哈希：读一遍 1000 个视频算哈希要几分钟，而这三项从目录项里直接就能拿到。
struct CacheKey: Hashable, Codable, Sendable {
    let path: String
    let size: Int64
    /// Unix 时间戳，取整到秒。
    ///
    /// 不同文件系统（APFS / exFAT / SMB）的时间精度不一致，亚秒级的抖动
    /// 会造成大量无谓的缓存失效，所以统一抹掉小数部分。
    let modified: Int64

    init(url: URL, size: Int64, modifiedAt: Date) {
        self.path = url.path(percentEncoded: false)
        self.size = size
        self.modified = Int64(modifiedAt.timeIntervalSince1970.rounded())
    }

    /// 磁盘缓存的文件名。取 SHA256 前 12 字节，碰撞概率可忽略且文件名不长。
    var digest: String {
        let material = "\(path)\u{0}\(size)\u{0}\(modified)"
        return SHA256.hash(data: Data(material.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 扫描阶段产出的条目。只含从目录项直接可得的信息，不含任何需要解码的内容。
struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let key: CacheKey

    var id: String { key.digest }
    var name: String { url.lastPathComponent }

    init(url: URL, size: Int64, modifiedAt: Date) {
        self.url = url
        self.key = CacheKey(url: url, size: size, modifiedAt: modifiedAt)
    }
}
