import Foundation

/// 把任意线程送来的画面更新合并成主线程上的单一待办。
///
/// mpv 的更新通知只表示“现在有更新”，并不携带某一帧的数据。因此无需逐条保留：
/// 真正绘制时读取 render context 和视图的最新状态即可。缩放或全屏动画期间适度
/// 限频，交互结束后由调用方请求一次强制绘制，确保最后尺寸不会漏掉。
final class RenderUpdateCoalescer: @unchecked Sendable {

    struct Metrics {
        let requested: Int
        let coalesced: Int
        let rendered: Int
        let maximumPendingMainTasks: Int
    }

    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> Void

    private let lock = NSLock()
    private let interactiveInterval: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let render: (_ force: Bool) -> Void

    private var isInteractive = false
    private var needsRender = false
    private var needsForcedRender = false
    private var isMainTaskPending = false
    private var isInvalidated = false
    private var scheduledID: UInt64 = 0
    private var lastRenderTime: TimeInterval?

    private var requestedCount = 0
    private var coalescedCount = 0
    private var renderedCount = 0
    private var pendingMainTaskCount = 0
    private var maximumPendingMainTaskCount = 0

    init(
        interactiveFramesPerSecond: Double = 30,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = { delay, action in
            if delay <= 0 {
                DispatchQueue.main.async(execute: action)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            }
        },
        render: @escaping (_ force: Bool) -> Void
    ) {
        interactiveInterval = 1 / max(interactiveFramesPerSecond, 1)
        self.now = now
        self.schedule = schedule
        self.render = render
    }

    /// 可从 mpv 回调线程或主线程调用。重复请求只更新“需要绘制”状态。
    func request(force: Bool = false) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }

        requestedCount += 1
        needsRender = true
        needsForcedRender = needsForcedRender || force
        if isMainTaskPending {
            coalescedCount += 1
            lock.unlock()
            return
        }

        scheduleNextLocked(delay: delayUntilNextRenderLocked(at: now()))
        lock.unlock()
    }

    /// 只应由主线程上的视图生命周期调用。
    func setInteractive(_ interactive: Bool) {
        lock.lock()
        isInteractive = interactive
        lock.unlock()
    }

    /// render context 拆除前调用。已经排到主线程的闭包会变成空操作。
    func invalidate() {
        lock.lock()
        isInvalidated = true
        needsRender = false
        needsForcedRender = false
        if isMainTaskPending {
            pendingMainTaskCount -= 1
        }
        isMainTaskPending = false
        scheduledID &+= 1
        lock.unlock()
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(
            requested: requestedCount,
            coalesced: coalescedCount,
            rendered: renderedCount,
            maximumPendingMainTasks: maximumPendingMainTaskCount
        )
    }

    private func scheduleNextLocked(delay: TimeInterval) {
        isMainTaskPending = true
        pendingMainTaskCount += 1
        maximumPendingMainTaskCount = max(maximumPendingMainTaskCount, pendingMainTaskCount)
        scheduledID &+= 1
        let id = scheduledID
        schedule(delay) { [weak self] in
            self?.drain(scheduledID: id)
        }
    }

    private func drain(scheduledID id: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))

        lock.lock()
        guard !isInvalidated, isMainTaskPending, scheduledID == id else {
            lock.unlock()
            return
        }

        let delay = delayUntilNextRenderLocked(at: now())
        if delay > 0 {
            // 当前闭包已开始执行，替换成一个延后闭包；队列中仍然只有一个待办。
            pendingMainTaskCount -= 1
            isMainTaskPending = false
            scheduleNextLocked(delay: delay)
            lock.unlock()
            return
        }

        pendingMainTaskCount -= 1
        needsRender = false
        let force = needsForcedRender
        needsForcedRender = false
        lock.unlock()

        render(force)

        lock.lock()
        guard !isInvalidated else {
            isMainTaskPending = false
            lock.unlock()
            return
        }
        renderedCount += 1
        lastRenderTime = now()

        if needsRender {
            // 绘制过程中又收到更新：当前绘制结束后才安排下一次，避免并行重入。
            isMainTaskPending = false
            scheduleNextLocked(delay: delayUntilNextRenderLocked(at: lastRenderTime!))
        } else {
            isMainTaskPending = false
        }
        lock.unlock()
    }

    private func delayUntilNextRenderLocked(at time: TimeInterval) -> TimeInterval {
        guard isInteractive, let lastRenderTime else { return 0 }
        return max(0, interactiveInterval - (time - lastRenderTime))
    }
}
