import XCTest
@testable import ClipFlow

/// 索引落盘绝不能把别人写的记录抹掉。
///
/// 触发场景：两扇窗口各自开着，各拿着一份自己创建那一刻的索引快照。
/// 只要落盘是「拿内存整份盖磁盘」，后写的那一方就会把先写那一方的成果全删掉——
/// 用户看到的是索引条数莫名其妙变少，封面和精灵图跟着重算一遍。
final class IndexDataLossTests: XCTestCase {

    // MARK: - 夹具

    private func makeKey(
        path: String,
        size: Int64 = 2048,
        modified: TimeInterval = 1_700_000_000
    ) -> CacheKey {
        CacheKey(
            url: URL(filePath: path), size: size, modifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    private func makeRecord(_ path: String) -> IndexRecord {
        var record = IndexRecord(key: makeKey(path: path))
        record.duration = 5
        record.width = 320
        record.height = 240
        record.coverTime = 1.5
        record.spriteTimestamps = [0.2, 0.8, 1.4]
        record.tileWidth = 64
        record.tileHeight = 48
        return record
    }

    private func temporaryIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "clipflow-loss-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "index.json", directoryHint: .notDirectory)
    }

    private func digestsOnDisk(_ url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(IndexFile.self, from: data)
        return Set(file.records.keys)
    }

    // MARK: - 两个写入方

    /// 复现：窗口 A 打开目录甲、窗口 B 打开目录乙，之后甲又多了一个文件。
    /// 修复前 B 那一批会被 A 整份覆盖掉。
    func testSaveKeepsRecordsWrittenByAnotherInstance() async throws {
        let url = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let windowA = MediaIndex(fileURL: url)
        await windowA.load()
        let a1 = makeRecord("/tmp/clipflow-loss/a1.mp4")
        await windowA.upsert(a1)
        try await windowA.save()

        // 第二扇窗口在 A 已经写过之后起来，看到的是 {a1}
        let windowB = MediaIndex(fileURL: url)
        await windowB.load()
        let b1 = makeRecord("/tmp/clipflow-loss/b1.mp4")
        let b2 = makeRecord("/tmp/clipflow-loss/b2.mp4")
        await windowB.upsert(b1)
        await windowB.upsert(b2)
        try await windowB.save()
        XCTAssertEqual(try digestsOnDisk(url).count, 3)

        // A 手里那份还停在 {a1}：目录里又多了一个文件，处理完照常落盘
        let a2 = makeRecord("/tmp/clipflow-loss/a2.mp4")
        await windowA.upsert(a2)
        try await windowA.save()

        let onDisk = try digestsOnDisk(url)
        XCTAssertEqual(
            onDisk,
            Set([a1.key.digest, a2.key.digest, b1.key.digest, b2.key.digest]),
            "另一扇窗口写进去的记录不能被这次落盘删掉"
        )
    }

    /// 没有本地改动时的落盘同样不能删东西。界面每滚一下都会顺手 save 一次。
    func testSaveWithoutLocalChangesDoesNotShrinkTheFile() async throws {
        let url = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let windowA = MediaIndex(fileURL: url)
        await windowA.load()
        let a1 = makeRecord("/tmp/clipflow-loss/only-a.mp4")
        await windowA.upsert(a1)
        try await windowA.save()

        let windowB = MediaIndex(fileURL: url)
        await windowB.load()
        await windowB.upsert(makeRecord("/tmp/clipflow-loss/only-b.mp4"))
        try await windowB.save()

        // A 什么都没做，只是又落了一次盘
        try await windowA.save()
        XCTAssertEqual(try digestsOnDisk(url).count, 2, "空落盘把别人的记录冲掉了")
    }

    /// 合并不能把刚删掉的记录又捡回来，否则 `pruneMissing` 之类的清理永远清不干净。
    func testRemovedRecordIsNotResurrectedByMerge() async throws {
        let url = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let index = MediaIndex(fileURL: url)
        await index.load()
        let keep = makeRecord("/tmp/clipflow-loss/keep.mp4")
        let drop = makeRecord("/tmp/clipflow-loss/drop.mp4")
        await index.upsert(keep)
        await index.upsert(drop)
        try await index.save()

        await index.remove(digest: drop.key.digest)
        try await index.save()

        XCTAssertEqual(try digestsOnDisk(url), Set([keep.key.digest]), "删掉的记录被合并捡回来了")
    }

    /// 第二扇窗口起来时会再调一次 load，不能把上一扇还没落盘的成果冲掉。
    func testSecondLoadKeepsUnsavedRecords() async throws {
        let url = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let index = MediaIndex(fileURL: url)
        await index.load()
        await index.upsert(makeRecord("/tmp/clipflow-loss/saved.mp4"))
        try await index.save()
        // 这一条还压在内存里没落盘
        await index.upsert(makeRecord("/tmp/clipflow-loss/pending.mp4"))

        // 第二扇窗口的 AppEnvironment 也会 load 一次
        await index.load()

        let count = await index.count
        XCTAssertEqual(count, 2, "重复 load 把内存里没落盘的记录冲掉了")
    }

    /// 索引是整机共用的一份，不跟着窗口走。每扇窗口各建一个就是本次数据丢失的根因。
    func testWindowsShareOneIndexInstance() async {
        XCTAssertTrue(MediaIndex.shared === MediaIndex.shared)
        let path = await MediaIndex.shared.fileURL.path(percentEncoded: false)
        XCTAssertTrue(path.hasSuffix("ClipFlow/index.json"), "共用实例指错了文件：\(path)")
    }
}
