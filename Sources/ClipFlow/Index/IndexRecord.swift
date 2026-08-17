import Foundation

/// 一个视频在索引里的全部落盘信息。
struct IndexRecord: Codable, Sendable {
    let key: CacheKey

    var duration: Double?
    var width: Int?
    var height: Int?

    // MARK: 第一阶段产物：封面

    /// 封面取自哪个时间点。
    var coverTime: Double?
    /// 所有候选位置都是近乎纯色，退回用第一个能解出来的帧。落库避免重复计算。
    var coverIsFallback: Bool = false
    /// 用户按 C 键手动指定的封面位置，优先级高于一切启发式。
    var manualCoverTime: Double?

    // MARK: 第二阶段产物：精灵图

    /// 精灵图每帧的实际时间戳。解码落点不会正好等于请求值，
    /// 悬停位置到帧的映射必须靠它。
    var spriteTimestamps: [Double] = []
    var tileWidth: Int = 0
    var tileHeight: Int = 0

    var failure: FailureRecord?

    /// 第一阶段是否已完成。格子能不能显示看它。
    var hasCover: Bool { failure == nil && duration != nil && coverTime != nil }
    /// 第二阶段是否已完成。悬停扫过和进度条预览能不能用看它。
    var hasSprite: Bool { failure == nil && !spriteTimestamps.isEmpty }

    init(key: CacheKey) {
        self.key = key
    }
}

/// 失败必须落库。
///
/// 老素材里必然混着坏文件、无视频流的文件、零时长文件。不记录失败的话，
/// 每次扫描都会重试同一批坏文件，整个流程会卡死在它们身上。
struct FailureRecord: Codable, Sendable {
    let reason: String
    let at: Date
}

/// 索引文件的整体结构。带版本号，将来改结构时能识别并重建。
struct IndexFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [String: IndexRecord] = [:]
}
