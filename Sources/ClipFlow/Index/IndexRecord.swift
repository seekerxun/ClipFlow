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
    /// 用户按 B 键手动指定的封面位置，优先级高于一切启发式。
    var manualCoverTime: Double?

    // MARK: 第二阶段产物：精灵图

    /// 精灵图每帧的实际时间戳。解码落点不会正好等于请求值，
    /// 悬停位置到帧的映射必须靠它。
    var spriteTimestamps: [Double] = []
    var tileWidth: Int = 0
    var tileHeight: Int = 0

    // MARK: 失败

    /// 两个阶段的失败分开记。
    ///
    /// 合成一个字段的话，精灵图超时会连带把已经生成好的封面判为无效——
    /// 格子会莫名其妙变空。两个阶段成本差一个数量级，失败原因也毫不相干。
    var coverFailure: FailureRecord?
    var spriteFailure: FailureRecord?

    /// 这条记录是从旧版 `failure` 单字段迁移过来的。不落盘，仅供载入时统计。
    ///
    /// 旧字段无法区分是哪个阶段失败的，也没有重试次数，只能整体丢弃、
    /// 让新策略重新判定一次。
    var migratedFromLegacyFailure: Bool = false

    /// 第一阶段是否已完成。格子能不能显示看它。
    var hasCover: Bool { coverFailure == nil && duration != nil && coverTime != nil }
    /// 第二阶段是否已完成。悬停扫过和进度条预览能不能用看它。
    var hasSprite: Bool { spriteFailure == nil && !spriteTimestamps.isEmpty }

    init(key: CacheKey) {
        self.key = key
    }

    /// 取指定阶段的失败记录。
    ///
    /// 刻意不叫 `failure`：那样残留的旧写法 `record.failure` 会被解析成未调用的
    /// 方法引用（非 nil），`XCTAssertNotNil` 之类的断言会静默通过。
    func failureRecord(for stage: IndexingPipeline.Stage) -> FailureRecord? {
        switch stage {
        case .cover: return coverFailure
        case .sprite: return spriteFailure
        }
    }

    mutating func setFailure(_ failure: FailureRecord?, for stage: IndexingPipeline.Stage) {
        switch stage {
        case .cover: coverFailure = failure
        case .sprite: spriteFailure = failure
        }
    }

    /// 这个阶段还允不允许再跑一次。
    func canRetry(_ stage: IndexingPipeline.Stage) -> Bool {
        failureRecord(for: stage)?.isRetryable ?? true
    }

    // MARK: - Codable

    /// 只列出要落盘的字段。`migratedFromLegacyFailure` 是运行期标记，不写文件；
    /// 旧字段 `failure` 也不在这里，因此重新编码时自然消失。
    private enum CodingKeys: String, CodingKey {
        case key, duration, width, height
        case coverTime, coverIsFallback, manualCoverTime
        case spriteTimestamps, tileWidth, tileHeight
        case coverFailure, spriteFailure
    }

    /// 旧版索引里的单一失败字段。只读，不再写回。
    private enum LegacyCodingKeys: String, CodingKey {
        case failure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(CacheKey.self, forKey: .key)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        coverTime = try c.decodeIfPresent(Double.self, forKey: .coverTime)
        coverIsFallback = try c.decodeIfPresent(Bool.self, forKey: .coverIsFallback) ?? false
        manualCoverTime = try c.decodeIfPresent(Double.self, forKey: .manualCoverTime)
        spriteTimestamps = try c.decodeIfPresent([Double].self, forKey: .spriteTimestamps) ?? []
        tileWidth = try c.decodeIfPresent(Int.self, forKey: .tileWidth) ?? 0
        tileHeight = try c.decodeIfPresent(Int.self, forKey: .tileHeight) ?? 0
        coverFailure = try c.decodeIfPresent(FailureRecord.self, forKey: .coverFailure)
        spriteFailure = try c.decodeIfPresent(FailureRecord.self, forKey: .spriteFailure)

        // 旧字段存在就丢掉：分不出阶段、也没有次数，留着只会继续永久跳过。
        // 丢掉之后这批文件会在新策略下重新试一次。
        if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
           legacy.contains(.failure),
           coverFailure == nil, spriteFailure == nil
        {
            migratedFromLegacyFailure = true
        }
    }
}

/// 失败的性质。决定这条失败还能不能重试。
enum FailureKind: String, Codable, Sendable {
    /// 外部进程超时。多半是当时机器忙，不是素材本身的问题。
    case timeout
    /// 解出来的帧是空白帧，或者图片数据本身不合法。
    case invalidImage
    /// 解码链路上的其它报错。
    case decodeError
    /// 素材本身就不支持（没有视频轨等）。重试多少次结果都一样。
    case unsupported

    /// 只有 `unsupported` 是判死刑，其余都给重试机会。
    var isRetryable: Bool { self != .unsupported }
}

/// 失败必须落库。
///
/// 老素材里必然混着坏文件、无视频流的文件、零时长文件。不记录失败的话，
/// 每次扫描都会重试同一批坏文件，整个流程会卡死在它们身上。
///
/// 但也不能一次失败就永久拉黑：超时只说明当时机器忙。所以记下性质和次数，
/// 可重试的那几类给够 `maxAttempts` 次再放弃。
struct FailureRecord: Codable, Sendable {
    /// 可重试类别的尝试上限。三次还不成，基本可以断定是素材的问题。
    static let maxAttempts = 3

    var reason: String
    var kind: FailureKind
    var at: Date
    /// 已经失败过几次（含本次）。
    var attempts: Int

    init(reason: String, kind: FailureKind, at: Date = Date(), attempts: Int = 1) {
        self.reason = reason
        self.kind = kind
        self.at = at
        self.attempts = max(1, attempts)
    }

    /// 还能不能再试一次。
    var isRetryable: Bool { kind.isRetryable && attempts < Self.maxAttempts }

    /// 在上一次失败之上再记一次。次数封顶，避免越界增长。
    static func next(after previous: FailureRecord?, reason: String, kind: FailureKind) -> FailureRecord {
        let attempts = min((previous?.attempts ?? 0) + 1, maxAttempts)
        return FailureRecord(reason: reason, kind: kind, at: Date(), attempts: attempts)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case reason, kind, at, attempts
    }

    /// 老记录只有 `{reason, at}`。缺字段就补默认值，不能整条解不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        // 认不出的类别按可重试处理，宁可多跑一次也不要凭一个陌生字符串永久拉黑
        kind = (try? c.decode(FailureKind.self, forKey: .kind)) ?? .decodeError
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
        attempts = max(1, (try? c.decode(Int.self, forKey: .attempts)) ?? 1)
    }
}

/// 索引文件的整体结构。带版本号，将来改结构时能识别并重建。
struct IndexFile: Codable, Sendable {
    /// 2：`failure` 拆成 `coverFailure` / `spriteFailure`，失败带类别与次数。
    static let currentVersion = 2

    var version: Int = currentVersion
    var records: [String: IndexRecord] = [:]
}
