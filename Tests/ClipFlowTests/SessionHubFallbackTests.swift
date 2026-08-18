import XCTest
@testable import ClipFlow

/// 一扇窗口都没有的时候，「打开文件」必须最终能开出一扇窗口把文件放进去。
///
/// 开出第一扇窗口靠的是启动时顺手记下的一个闭包，而记它的位置是 SwiftUI 求值菜单
/// 时的副作用——SwiftUI 并不保证这一步一定会跑。真没跑的话，文件会一直躺在待取队列
/// 里，屏幕上既没有窗口也没有报错，看起来就是「文件凭空消失了」。
/// 这几条用例盯的就是这个兜底：闭包在也好、不在也好、叫了不管用也好，都得有窗口。
@MainActor
final class SessionHubFallbackTests: XCTestCase {

    private let sample = URL(fileURLWithPath: "/tmp/clipflow-tests/sample.mp4")

    /// 把两个等待时长都调短，测试不用干等。
    private func makeHub(windowWait: Duration = .milliseconds(80)) -> SessionHub {
        let hub = SessionHub()
        hub.batchWindow = .milliseconds(5)
        hub.windowWait = windowWait
        return hub
    }

    /// 连开窗闭包都没拿到：不能就这么把文件丢了，必须直接开一扇兜底窗口。
    func testFallbackWindowOpensWhenMainOpenerWasNeverCaptured() async throws {
        let hub = makeHub()
        var fallbacks = 0
        hub.makeFallbackWindow = { fallbacks += 1 }

        hub.open([sample])
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(fallbacks, 1)
        // 文件还留着，等新窗口起来自己来取。
        XCTAssertEqual(hub.takePending(), [sample])
    }

    /// 闭包拿到了也叫了，但一扇窗口都没开出来：看门狗到点后仍要兜住。
    func testFallbackWindowOpensWhenCapturedOpenerProducesNoWindow() async throws {
        let hub = makeHub()
        var fallbacks = 0
        var asked = 0
        hub.makeFallbackWindow = { fallbacks += 1 }
        hub.captureMainOpener { asked += 1 }

        hub.open([sample])
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fallbacks, 1)
        XCTAssertEqual(hub.takePending(), [sample])
    }

    /// 正常情况：闭包叫出了窗口，窗口把文件取走了，就不该再多开一扇兜底窗口。
    func testNoFallbackWindowWhenOpenedWindowTakesTheFiles() async throws {
        let hub = makeHub(windowWait: .milliseconds(300))
        var fallbacks = 0
        var asked = 0
        hub.makeFallbackWindow = { fallbacks += 1 }
        hub.captureMainOpener { asked += 1 }

        hub.open([sample])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(asked, 1)
        // 窗口起来了，把文件取走。
        XCTAssertEqual(hub.takePending(), [sample])

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fallbacks, 0)
    }

    /// 不能因为加了兜底就退回「一个文件一扇窗口」：一次送来 20 个文件，
    /// 攒成一批之后只该叫一扇窗口，20 个文件全都在里面。
    func testManyFilesStillAskForExactlyOneWindow() async throws {
        let hub = makeHub()
        var fallbacks = 0
        hub.makeFallbackWindow = { fallbacks += 1 }

        let urls = (0 ..< 20).map { URL(fileURLWithPath: "/tmp/clipflow-tests/\($0).mp4") }
        for url in urls {
            hub.open([url])
        }
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(fallbacks, 1)
        XCTAssertEqual(hub.takePending(), urls)
    }

    /// 等窗口期间又送来一批文件：搭上同一趟车，不该再叫第二扇窗口。
    func testSecondBatchWhileWaitingDoesNotAskForAnotherWindow() async throws {
        let hub = makeHub(windowWait: .milliseconds(400))
        var fallbacks = 0
        hub.makeFallbackWindow = { fallbacks += 1 }

        hub.open([sample])
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fallbacks, 1)

        let second = URL(fileURLWithPath: "/tmp/clipflow-tests/second.mp4")
        hub.open([second])
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(fallbacks, 1)
        XCTAssertEqual(hub.takePending(), [sample, second])
    }
}
