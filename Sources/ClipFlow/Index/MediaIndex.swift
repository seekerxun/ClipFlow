import Foundation

/// 索引的读写入口。所有访问都过这个 actor，避免并发写。
///
/// 存储形式刻意保持简单：一个 JSON 文件 + 原子写。几千条以内完全够用，
/// 真到几万条再换数据库。一上来就上 Core Data 是过度设计。
actor MediaIndex {

    private var file = IndexFile()
    private var unsavedCount = 0

    let fileURL: URL

    /// 上一次 `load()` 做了什么。出问题时能一眼看出是迁移丢的还是本来就没有。
    struct LoadReport: Sendable {
        /// 旧版 `failure` 单字段被丢弃的记录数，这些文件会重新试一次。
        var legacyFailuresDropped = 0
        /// 整份解不出来、逐条抢救时丢掉的坏记录数。
        var unreadableRecordsDropped = 0
        /// 走了逐条抢救而不是整份解码。
        var salvaged = false
        /// 连逐条抢救都不行，原文件已备份、内存里保持空索引。
        var unreadable = false
    }

    private(set) var lastLoadReport = LoadReport()

    /// `load()` 至少跑过一次。没跑过就落盘等于拿空索引覆盖用户的缓存。
    private var hasLoaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appending(path: "ClipFlow", directoryHint: .isDirectory)
            self.fileURL = base.appending(path: "index.json", directoryHint: .notDirectory)
        }
    }

    // MARK: - 载入 / 保存

    func load() {
        var report = LoadReport()
        defer {
            lastLoadReport = report
            hasLoaded = true
        }

        guard let data = try? Data(contentsOf: fileURL) else { return }

        var loaded: IndexFile
        if let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) {
            // 比当前版本新的文件不认识，按空索引处理，也不要拿它去猜结构
            guard decoded.version <= IndexFile.currentVersion else { return }
            loaded = decoded
        } else if let salvage = Self.salvageRecords(from: data) {
            // 整份解不出来时绝不能当成「没有索引」——那等于把用户攒下的缓存
            // 全部作废重算。逐条解，只丢真正坏掉的那几条。
            loaded = IndexFile(version: IndexFile.currentVersion, records: salvage.records)
            report.salvaged = true
            report.unreadableRecordsDropped = salvage.dropped
            unsavedCount += 1
        } else {
            // 连逐条都读不出来：先把原文件留一份，再让后续的 save 覆盖，
            // 否则用户丢的是全部而不是一份可事后排查的备份。
            report.unreadable = true
            Self.backUpUnreadable(at: fileURL)
            return
        }

        report.legacyFailuresDropped = loaded.records.values
            .filter(\.migratedFromLegacyFailure).count
        if report.legacyFailuresDropped > 0 || loaded.version != IndexFile.currentVersion {
            // 迁移结果要有机会落盘，否则每次启动都重来一遍
            unsavedCount += 1
        }
        loaded.version = IndexFile.currentVersion
        file = loaded
    }

    /// 整份 JSON 解不出来时逐条抢救。
    ///
    /// 返回 nil 表示连最外层结构都不成立，那才是真的没救。
    private static func salvageRecords(from data: Data) -> (records: [String: IndexRecord], dropped: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["records"] as? [String: Any]
        else { return nil }

        let decoder = JSONDecoder()
        var records: [String: IndexRecord] = [:]
        var dropped = 0
        for (digest, value) in raw {
            guard let blob = try? JSONSerialization.data(withJSONObject: value),
                  let record = try? decoder.decode(IndexRecord.self, from: blob)
            else {
                dropped += 1
                continue
            }
            records[digest] = record
        }
        return (records, dropped)
    }

    private static func backUpUnreadable(at url: URL) {
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt")
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    func save() throws {
        // 启动期是有竞态的：`AppEnvironment` 把 load 丢进 Task，而空队列的
        // ThumbnailQueue 会立刻 save 一次。save 先跑完的话，用户攒了几千条的索引
        // 会被内存里那份空的整份覆盖掉。没 load 过就不许盖已有文件。
        guard hasLoaded || !FileManager.default.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else { return }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
        unsavedCount = 0
    }

    /// 攒够一批再落盘。每条都写的话，1000 个文件就是 1000 次整份 JSON 重写。
    func saveIfNeeded(threshold: Int = 50) throws {
        guard unsavedCount >= threshold else { return }
        try save()
    }

    // MARK: - 记录

    func record(for key: CacheKey) -> IndexRecord? {
        guard let existing = file.records[key.digest] else { return nil }
        // 摘要相同但三要素不同，说明是哈希碰撞，当作没有
        guard existing.key == key else { return nil }
        return existing
    }

    func upsert(_ record: IndexRecord) {
        file.records[record.key.digest] = record
        unsavedCount += 1
    }

    func remove(digest: String) {
        file.records.removeValue(forKey: digest)
        unsavedCount += 1
    }

    var count: Int { file.records.count }

    var allRecords: [IndexRecord] { Array(file.records.values) }

    /// 这个条目在指定阶段还需不需要处理。
    ///
    /// 三种情况要做：没有记录、记录不完整、或者记录在但图片被系统清掉了。
    ///
    /// 失败要落库，否则每次扫描都会重试同一批坏文件。但只看「有没有失败过」
    /// 太粗：超时说明当时机器忙，跟文件坏了完全是两回事。所以按阶段分别判，
    /// 且只有 `unsupported` 或者试满 `maxAttempts` 次才真正放弃。
    func needsWork(for item: MediaItem, stage: IndexingPipeline.Stage) -> Bool {
        guard let existing = record(for: item.key) else { return true }
        guard existing.canRetry(stage) else { return false }
        switch stage {
        case .cover:
            return !existing.hasCover || !ThumbnailStore.hasCover(digest: item.key.digest)
        case .sprite:
            return !existing.hasSprite || !ThumbnailStore.hasSprite(digest: item.key.digest)
        }
    }

    /// 清掉索引里已经不存在于磁盘的条目。
    func pruneMissing() {
        let fm = FileManager.default
        for (digest, record) in file.records
        where !fm.fileExists(atPath: record.key.path) {
            file.records.removeValue(forKey: digest)
            unsavedCount += 1
        }
    }
}
