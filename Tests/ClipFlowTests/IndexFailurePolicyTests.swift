import XCTest
@testable import ClipFlow

/// 失败落库策略：分阶段、可重试、旧格式能迁移。
final class IndexFailurePolicyTests: XCTestCase {

    // MARK: - 夹具

    private func makeKey(
        path: String = "/tmp/clipflow-test/sample.mp4",
        size: Int64 = 1024,
        modified: TimeInterval = 1_700_000_000
    ) -> CacheKey {
        CacheKey(
            url: URL(filePath: path), size: size, modifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    private func makeItem(for key: CacheKey) -> MediaItem {
        MediaItem(
            url: URL(filePath: key.path),
            size: key.size,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(key.modified))
        )
    }

    /// 已经出好封面和精灵图的完整记录。
    private func makeCompleteRecord(key: CacheKey) -> IndexRecord {
        var record = IndexRecord(key: key)
        record.duration = 9
        record.width = 834
        record.height = 1112
        record.coverTime = 3.18
        record.spriteTimestamps = [0.25, 0.6, 1.0]
        record.tileWidth = 107
        record.tileHeight = 144
        return record
    }

    private func temporaryIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "clipflow-index-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "index.json", directoryHint: .notDirectory)
    }

    // MARK: - (i) 精灵图失败不能连累封面

    func testSpriteFailureLeavesCoverIntact() {
        var record = makeCompleteRecord(key: makeKey())
        record.spriteFailure = FailureRecord(reason: "ffmpeg 超时", kind: .timeout)

        XCTAssertTrue(record.hasCover, "精灵图超时不应该把已经生成好的封面判为无效")
        XCTAssertFalse(record.hasSprite)
        XCTAssertNil(record.coverFailure)
    }

    func testCoverFailureLeavesSpriteIntact() {
        var record = makeCompleteRecord(key: makeKey())
        record.coverFailure = FailureRecord(reason: "解码失败", kind: .decodeError)

        XCTAssertFalse(record.hasCover)
        XCTAssertTrue(record.hasSprite)
    }

    func testSpriteFailureDoesNotStopCoverStageFromBeingConsidered() async {
        let key = makeKey()
        let index = MediaIndex(fileURL: temporaryIndexURL())
        var record = makeCompleteRecord(key: key)
        record.spriteFailure = FailureRecord(reason: "不支持", kind: .unsupported)
        await index.upsert(record)

        let item = makeItem(for: key)
        // 精灵图判了死刑，不再排队
        let needsSprite = await index.needsWork(for: item, stage: .sprite)
        XCTAssertFalse(needsSprite)
        // 但封面记录本身完好，没有被精灵图的失败牵连
        let stored = await index.record(for: key)
        XCTAssertEqual(stored?.hasCover, true)
    }

    // MARK: - (ii) 超时可重试，满三次为止

    func testTimeoutIsRetriedUpToThreeAttempts() async {
        let key = makeKey()
        let index = MediaIndex(fileURL: temporaryIndexURL())
        let item = makeItem(for: key)

        var record = makeCompleteRecord(key: key)
        var failure: FailureRecord?

        for attempt in 1 ... FailureRecord.maxAttempts {
            failure = FailureRecord.next(after: failure, reason: "超时", kind: .timeout)
            XCTAssertEqual(failure?.attempts, attempt)
            record.coverFailure = failure
            await index.upsert(record)

            let needs = await index.needsWork(for: item, stage: .cover)
            if attempt < FailureRecord.maxAttempts {
                XCTAssertTrue(needs, "第 \(attempt) 次超时之后还应该再试")
            } else {
                XCTAssertFalse(needs, "试满 \(FailureRecord.maxAttempts) 次之后不再重试")
            }
        }
    }

    func testAttemptsAreCappedAtMax() {
        var failure: FailureRecord?
        for _ in 0 ..< 10 {
            failure = FailureRecord.next(after: failure, reason: "超时", kind: .timeout)
        }
        XCTAssertEqual(failure?.attempts, FailureRecord.maxAttempts)
        XCTAssertEqual(failure?.isRetryable, false)
    }

    func testInvalidImageAndDecodeErrorAreRetryable() {
        for kind in [FailureKind.timeout, .invalidImage, .decodeError] {
            let failure = FailureRecord(reason: "x", kind: kind, attempts: 1)
            XCTAssertTrue(failure.isRetryable, "\(kind.rawValue) 应该可以重试")
        }
    }

    // MARK: - (iii) unsupported 永不重试

    func testUnsupportedIsNeverRetried() async {
        let key = makeKey()
        let index = MediaIndex(fileURL: temporaryIndexURL())
        var record = makeCompleteRecord(key: key)
        record.coverTime = nil
        record.coverFailure = FailureRecord(reason: "没有视频轨", kind: .unsupported, attempts: 1)
        await index.upsert(record)

        let needs = await index.needsWork(for: makeItem(for: key), stage: .cover)
        XCTAssertFalse(needs)
        XCTAssertFalse(record.coverFailure!.isRetryable)
        XCTAssertFalse(FailureKind.unsupported.isRetryable)
    }

    // MARK: - 错误归类

    func testErrorMapping() {
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: ProcessRunner.RunnerError.timedOut), .timeout
        )
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: MediaProbe.ProbeError.timedOut), .timeout
        )
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: MediaProbe.ProbeError.noVideoTrack), .unsupported
        )
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: FFmpegSpriteGenerator.GenerateError.invalidImage),
            .invalidImage
        )
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: SpriteGenerator.GenerateError.encodeFailed),
            .decodeError
        )
        XCTAssertEqual(
            IndexingPipeline.failureKind(
                for: ProcessRunner.RunnerError.failed(status: 1, message: "boom")
            ),
            .decodeError
        )
    }

    // MARK: - (iv) 旧格式迁移

    func testLegacyIndexLoadsWithoutDataLossAndDropsFailure() async throws {
        let key = makeKey(path: "/tmp/clipflow-test/legacy.mp4", size: 9_919_358)
        let url = temporaryIndexURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 老版本写出来的样子：version 1，单一 failure，没有 kind / attempts
        let legacy = """
        {
          "version": 1,
          "records": {
            "\(key.digest)": {
              "key": { "path": "\(key.path)", "size": \(key.size), "modified": \(key.modified) },
              "duration": 9.086,
              "width": 834,
              "height": 1112,
              "coverTime": 3.18,
              "coverIsFallback": false,
              "spriteTimestamps": [0.25, 0.6333, 1.0],
              "tileWidth": 107,
              "tileHeight": 144,
              "failure": { "reason": "RunnerError.timedOut", "at": 776000000.0 }
            }
          }
        }
        """
        try Data(legacy.utf8).write(to: url)

        let index = MediaIndex(fileURL: url)
        await index.load()

        let count = await index.count
        XCTAssertEqual(count, 1, "迁移不能把记录整条丢掉")

        let loaded = await index.record(for: key)
        let record = try XCTUnwrap(loaded)
        // 产物全部保留
        XCTAssertEqual(record.duration ?? 0, 9.086, accuracy: 0.001)
        XCTAssertEqual(record.width, 834)
        XCTAssertEqual(record.height, 1112)
        XCTAssertEqual(record.coverTime ?? 0, 3.18, accuracy: 0.001)
        XCTAssertEqual(record.spriteTimestamps.count, 3)
        XCTAssertEqual(record.tileWidth, 107)
        // 旧失败被丢掉，两个阶段都能重新试一次
        XCTAssertNil(record.coverFailure)
        XCTAssertNil(record.spriteFailure)
        XCTAssertTrue(record.migratedFromLegacyFailure)
        XCTAssertTrue(record.hasCover)
        XCTAssertTrue(record.hasSprite)

        let report = await index.lastLoadReport
        XCTAssertEqual(report.legacyFailuresDropped, 1)
        XCTAssertFalse(report.unreadable)

        // 存回去之后旧字段不该再出现
        try await index.save()
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("\"failure\""))
        XCTAssertTrue(raw.contains("\"version\":\(IndexFile.currentVersion)"))
    }

    func testLegacyFailureRecordShapeDecodesTolerantly() throws {
        let json = #"{ "reason": "旧的失败", "at": 776000000.0 }"#
        let failure = try JSONDecoder().decode(FailureRecord.self, from: Data(json.utf8))
        XCTAssertEqual(failure.reason, "旧的失败")
        XCTAssertEqual(failure.kind, .decodeError)
        XCTAssertEqual(failure.attempts, 1)
        XCTAssertTrue(failure.isRetryable)
    }

    func testUnknownFailureKindFallsBackToRetryable() throws {
        let json = #"{ "reason": "x", "kind": "somethingNew", "at": 776000000.0, "attempts": 2 }"#
        let failure = try JSONDecoder().decode(FailureRecord.self, from: Data(json.utf8))
        XCTAssertEqual(failure.kind, .decodeError)
        XCTAssertEqual(failure.attempts, 2)
    }

    // MARK: - 坏文件不能把整份索引清空

    func testCorruptRecordDoesNotWipeTheWholeIndex() async throws {
        let good = makeKey(path: "/tmp/clipflow-test/good.mp4")
        let url = temporaryIndexURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 第二条缺 key，整份 JSON 会解不出来
        let mixed = """
        {
          "version": 2,
          "records": {
            "\(good.digest)": {
              "key": { "path": "\(good.path)", "size": \(good.size), "modified": \(good.modified) },
              "duration": 5.0, "width": 100, "height": 200, "coverTime": 1.0,
              "coverIsFallback": false, "spriteTimestamps": [1.0], "tileWidth": 10, "tileHeight": 20
            },
            "broken": { "duration": 1.0 }
          }
        }
        """
        try Data(mixed.utf8).write(to: url)

        let index = MediaIndex(fileURL: url)
        await index.load()

        let count = await index.count
        XCTAssertEqual(count, 1, "只该丢掉坏的那一条，不是整份索引")
        let report = await index.lastLoadReport
        XCTAssertTrue(report.salvaged)
        XCTAssertEqual(report.unreadableRecordsDropped, 1)
        let survivor = await index.record(for: good)
        XCTAssertNotNil(survivor)
    }

    func testBlankFrameMapsToInvalidImage() {
        XCTAssertEqual(
            IndexingPipeline.failureKind(for: FFmpegSpriteGenerator.GenerateError.blankFrame),
            .invalidImage
        )
    }

    func testUnreadableFileIsBackedUpAndNotSilentlyDiscarded() async throws {
        let url = temporaryIndexURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("这根本不是 JSON".utf8).write(to: url)

        let index = MediaIndex(fileURL: url)
        await index.load()

        let report = await index.lastLoadReport
        XCTAssertTrue(report.unreadable)
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt").appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
    }
}
