import Foundation

/// 索引的读写入口。所有访问都过这个 actor，避免并发写。
///
/// 存储形式刻意保持简单：一个 JSON 文件 + 原子写。几千条以内完全够用，
/// 真到几万条再换数据库。一上来就上 Core Data 是过度设计。
actor MediaIndex {

    /// 全应用共用这一个索引。
    ///
    /// 索引是按文件摘要组织的整机素材缓存，本来就不属于某一扇窗口。每扇窗口各建一个的话，
    /// 每个都攥着自己创建那一刻的快照，落盘又是整份覆盖，于是谁后写谁说了算：
    /// 另一扇窗口这期间新建的记录会被整份抹掉。多窗口能正常播放之后这条路径才真正被走到，
    /// 表现就是索引莫名其妙变少。
    static let shared = MediaIndex()

    private var file = IndexFile()
    private var unsavedCount = 0

    /// 本次运行里主动删掉的摘要。落盘合并时要按它把磁盘上的旧条目一并去掉，
    /// 否则合并会把刚删的记录又捡回来。
    private var removedDigests: Set<String> = []

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
        // 共用一个实例之后，每扇窗口起来都会各调一次 load。第二次再照着磁盘重读一遍，
        // 会把前一扇窗口刚做好、还没落盘的记录整份冲掉。载入只做第一次。
        guard !hasLoaded else { return }

        var report = LoadReport()
        defer {
            lastLoadReport = report
            hasLoaded = true
        }

        guard let data = try? Data(contentsOf: fileURL) else { return }

        var loaded: IndexFile
        if let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) {
            // 比当前版本新的文件不认识，按空索引处理，也不要拿它去猜结构。
            // 但后面的 save 会把它盖掉，所以先留一份备份再撒手。
            guard decoded.version <= IndexFile.currentVersion else {
                Self.backUpUnreadable(at: fileURL)
                return
            }
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
        let exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))

        // 启动期是有竞态的：`AppEnvironment` 把 load 丢进 Task，而空队列的
        // ThumbnailQueue 会立刻 save 一次。save 先跑完的话，用户攒了几千条的索引
        // 会被内存里那份空的整份覆盖掉。没 load 过就不许盖已有文件。
        guard hasLoaded || !exists else { return }

        // 没有任何待写的改动就别动这个文件。界面每滚一下都会顺手 save 一次，
        // 这里挡掉的是纯粹的重复重写。
        guard unsavedCount > 0 || !exists else { return }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        file = mergedWithDisk()
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
        unsavedCount = 0
        removedDigests.removeAll()
    }

    /// 落盘前先把磁盘上那份合进来，只增改自己知道的，绝不删自己不知道的。
    ///
    /// 每次 save 都是整份覆盖，因此只要有第二个写入方（另一个进程、手工改过的文件，
    /// 或者哪天又有人给某个模块单开一份索引），内存里没见过的记录就会被整份抹掉。
    /// 合并之后，「盖掉一条自己从没听说过的记录」这件事在结构上就不可能发生了。
    ///
    /// 两边都有的记录以内存为准：写的人就是刚干完活的那个，它手上那份最新。
    private func mergedWithDisk() -> IndexFile {
        guard let data = try? Data(contentsOf: fileURL) else { return file }

        let onDisk: [String: IndexRecord]
        if let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) {
            // 认不出的新版本不合并，也不猜它的结构；load 已经给它留过备份
            guard decoded.version <= IndexFile.currentVersion else { return file }
            onDisk = decoded.records
        } else if let salvage = Self.salvageRecords(from: data) {
            onDisk = salvage.records
        } else {
            return file
        }

        var merged = file
        for (digest, record) in onDisk
        where merged.records[digest] == nil && !removedDigests.contains(digest) {
            merged.records[digest] = record
        }
        return merged
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
        removedDigests.remove(record.key.digest)
        unsavedCount += 1
    }

    func remove(digest: String) {
        file.records.removeValue(forKey: digest)
        removedDigests.insert(digest)
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
            removedDigests.insert(digest)
            unsavedCount += 1
        }
    }
}
