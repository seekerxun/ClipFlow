import Foundation

/// 索引的读写入口。所有访问都过这个 actor，避免并发写。
///
/// 存储形式刻意保持简单：一个 JSON 文件 + 原子写。几千条以内完全够用，
/// 真到几万条再换数据库。一上来就上 Core Data 是过度设计。
actor MediaIndex {

    private var file = IndexFile()
    private var unsavedCount = 0

    let fileURL: URL

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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) else {
            // 解不出来就当没有，重建一遍即可，不值得为此中断启动
            return
        }
        guard decoded.version == IndexFile.currentVersion else { return }
        file = decoded
    }

    func save() throws {
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
    /// 已经明确失败过的不再重试——这正是失败要落库的原因。
    func needsWork(for item: MediaItem, stage: IndexingPipeline.Stage) -> Bool {
        guard let existing = record(for: item.key) else { return true }
        if existing.failure != nil { return false }
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
