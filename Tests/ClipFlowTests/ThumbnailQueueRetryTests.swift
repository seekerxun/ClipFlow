import XCTest
@testable import ClipFlow

/// 可重试的失败要在本轮会话里自己排回来，而不是等条目滚出可见窗口再滚回来。
///
/// 用户盯着的那一格恰恰是最想被修好的那一格，而它正因为一直可见，
/// 反而永远等不到「重新进入可见窗口」这个触发条件。
@MainActor
final class ThumbnailQueueRetryTests: XCTestCase {

    /// 一直可见的条目失败后仍会重投，并且刚好试满 `maxAttempts` 次就停。
    func testRetryableFailureRequeuesVisibleItemAndStopsAfterMaxAttempts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try brokenItem(in: directory)
        let index = MediaIndex(fileURL: directory.appending(path: "index.json"))
        await index.load()

        let queue = ThumbnailQueue(index: index)
        // 只是不想让测试为这点等待白等；重投逻辑本身跟具体等多久无关。
        queue.retryDelay = 0.02
        queue.reset(items: [item])
        // 全程不调用 disappear：这正是老写法永远等不到第二次机会的场景。
        queue.appear(id: item.id)

        try await drain(queue, timeout: 60)

        XCTAssertEqual(queue.activeCount, 0)
        XCTAssertEqual(queue.pendingCount, 0, "试满次数之后要彻底出队，不能一直挂在队列里")
        // 封面、精灵图各 maxAttempts 次。老写法每个阶段只会跑一次，总数是 2。
        XCTAssertEqual(
            queue.submittedCount,
            2 * FailureRecord.maxAttempts,
            "两个阶段应各重投到 \(FailureRecord.maxAttempts) 次为止"
        )

        let recorded = await index.record(for: item.key)
        let stored = try XCTUnwrap(recorded)
        XCTAssertEqual(stored.coverFailure?.attempts, FailureRecord.maxAttempts)
        XCTAssertEqual(stored.spriteFailure?.attempts, FailureRecord.maxAttempts)
        XCTAssertEqual(stored.coverFailure?.isRetryable, false)
    }

    /// 失败之后不许接着立刻再跑一遍：先排到当前这批活后面去。
    func testFailedItemIsHeldInsteadOfImmediatelyRerunning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try brokenItem(in: directory)
        let index = MediaIndex(fileURL: directory.appending(path: "index.json"))
        await index.load()

        let queue = ThumbnailQueue(index: index)
        queue.retryDelay = 5
        queue.reset(items: [item])
        defer { queue.reset(items: []) }
        queue.appear(id: item.id)

        // 等第一次失败落地
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !(queue.submittedCount >= 1 && queue.activeCount == 0) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.submittedCount, 1)

        // 等待时间还没到，队列不该空转着把同一条反复重投
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(queue.submittedCount, 1, "重试要等在闸门后面，不能失败一次就立刻再跑一次")
        XCTAssertEqual(queue.activeCount, 0)
        XCTAssertEqual(queue.pendingCount, 1, "但条目要留在队列里，等着后面这一轮重试")
    }

    // MARK: - 夹具

    /// 每次都真实失败、且失败类别可重试的素材。
    private func brokenItem(in directory: URL) throws -> MediaItem {
        let broken = directory.appending(path: "broken.mp4")
        try Data("这不是视频".utf8).write(to: broken)
        let values = try broken.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        return MediaItem(
            url: broken,
            size: Int64(try XCTUnwrap(values.fileSize)),
            modifiedAt: values.contentModificationDate ?? Date()
        )
    }

    /// 等队列彻底停下来。跑不完就让断言那边报错，不在这里无限等。
    private func drain(_ queue: ThumbnailQueue, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.activeCount == 0, queue.pendingCount == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ClipFlowQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
