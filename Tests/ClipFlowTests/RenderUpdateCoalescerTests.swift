import XCTest
@testable import ClipFlow

@MainActor
final class RenderUpdateCoalescerTests: XCTestCase {

    func testRepeatedUpdatesKeepOnlyOnePendingMainTask() {
        let scheduler = FakeScheduler()
        var renders = 0
        let coalescer = RenderUpdateCoalescer(
            schedule: scheduler.schedule,
            render: { _ in renders += 1 }
        )

        for _ in 0 ..< 100 {
            coalescer.request()
        }

        XCTAssertEqual(scheduler.work.count, 1)
        scheduler.runNext()
        let metrics = coalescer.metrics()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(metrics.requested, 100)
        XCTAssertEqual(metrics.coalesced, 99)
        XCTAssertEqual(metrics.rendered, 1)
        XCTAssertEqual(metrics.maximumPendingMainTasks, 1)
    }

    func testConcurrentUpdatesKeepOnlyOnePendingMainTask() {
        let scheduler = FakeScheduler()
        var renders = 0
        let coalescer = RenderUpdateCoalescer(
            schedule: scheduler.schedule,
            render: { _ in renders += 1 }
        )

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            coalescer.request()
        }

        XCTAssertEqual(scheduler.work.count, 1)
        scheduler.runNext()
        let metrics = coalescer.metrics()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(metrics.requested, 1_000)
        XCTAssertEqual(metrics.coalesced, 999)
        XCTAssertEqual(metrics.maximumPendingMainTasks, 1)
    }

    func testInteractiveThrottleAndFinalForcedFrame() {
        let scheduler = FakeScheduler()
        var clock: TimeInterval = 10
        var renders: [Bool] = []
        let coalescer = RenderUpdateCoalescer(
            now: { clock },
            schedule: scheduler.schedule,
            render: { renders.append($0) }
        )

        coalescer.request()
        scheduler.runNext()
        coalescer.setInteractive(true)
        clock += 0.001
        for _ in 0 ..< 50 {
            coalescer.request()
        }

        XCTAssertEqual(scheduler.work.count, 1)
        let delay = scheduler.work[0].delay
        XCTAssertGreaterThan(delay, 0.03)
        clock += delay + 0.001
        scheduler.runNext()

        coalescer.setInteractive(false)
        coalescer.request(force: true)
        scheduler.runNext()
        XCTAssertEqual(renders, [false, false, true])
        XCTAssertEqual(coalescer.metrics().maximumPendingMainTasks, 1)
    }

    func testInvalidationMakesTrailingTaskNoOp() {
        let scheduler = FakeScheduler()
        var rendered = false
        let coalescer = RenderUpdateCoalescer(
            schedule: scheduler.schedule,
            render: { _ in rendered = true }
        )

        coalescer.request()
        coalescer.invalidate()
        scheduler.runNext()

        XCTAssertFalse(rendered)
    }
}

@MainActor
private final class FakeScheduler {
    struct Work {
        let delay: TimeInterval
        let action: () -> Void
    }

    var work: [Work] = []

    func schedule(delay: TimeInterval, action: @escaping () -> Void) {
        work.append(Work(delay: delay, action: action))
    }

    func runNext() {
        work.removeFirst().action()
    }
}
