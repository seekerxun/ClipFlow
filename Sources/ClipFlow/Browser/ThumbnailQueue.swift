import Foundation
import Observation

/// 可见优先级调度。打开目录时不要把全部文件一次性丢进 `IndexingPipeline.process`。
///
/// 只为当前可见行 / 格 + 前后各一屏排队；`onAppear` 入队，`onDisappear` 降级或取消。
/// 空闲后再以最低优先级慢慢补齐剩余项。并发上限沿用流水线的
/// `min(4, activeProcessorCount / 2)`，不会另开几百个 Task。
@MainActor
@Observable
final class ThumbnailQueue {

    enum Location: Int, Sendable {
        case visible = 0
        case nearby = 1
        case idle = 2
    }

    @ObservationIgnored let index: MediaIndex
    var startFraction: Double

    @ObservationIgnored var onRecord: ((IndexRecord) -> Void)?
    /// 队列检查时关掉，避免对用户素材目录真正抽帧。
    @ObservationIgnored var enableProcessing = true
    /// 可重试失败之后要压住多久才放回候选集合。
    ///
    /// 只要求「不要接着立刻再跑一遍」：可重试的失败以超时和临时解码错误为主，
    /// 原地重投既救不了这一条，还会把可见窗口里其他条目一直挤在后面。压一小会儿
    /// 就够——正在跑的那批活先跑完，重投也就自然排到它们后面。一条彻底坏掉的
    /// 素材最多只多等 `maxAttempts - 1` 次这个时间，用户感觉不出来。
    @ObservationIgnored var retryDelay: TimeInterval = 1.5

    private(set) var activeCount = 0
    private(set) var submittedCount = 0
    private(set) var pendingCount = 0

    @ObservationIgnored private var itemsByID: [String: MediaItem] = [:]
    @ObservationIgnored private var orderedIDs: [String] = []
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var runningTasks: [String: Task<Void, Never>] = [:]
    /// 按「条目 + 阶段」拉黑，而不是整条拉黑。
    ///
    /// 只有确定没救的才进来：`unsupported`，或者已经试满 `FailureRecord.maxAttempts` 次。
    /// 一次超时就把整条永久踢出队列，是封面莫名其妙不出图的主因之一。
    @ObservationIgnored private var blockedStages: Set<String> = []
    /// 本轮会话里各阶段真正跑失败了几次。索引拿不到记录时的兜底，防止空转。
    @ObservationIgnored private var stageAttempts: [String: Int] = [:]
    /// 刚失败、正在等下一次重试的条目。挑选时一律跳过，到点由 `releaseRetry` 放回。
    @ObservationIgnored private var heldForRetry: Set<String> = []
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var doneCover: Set<String> = []
    @ObservationIgnored private var doneSprite: Set<String> = []
    @ObservationIgnored private var idleArmed = false
    @ObservationIgnored private var generation = 0

    init(index: MediaIndex, startFraction: Double = CoverPicker.defaultStartFraction) {
        self.index = index
        self.startFraction = startFraction
    }

    var visibleJobCount: Int { jobs.values.filter { $0.location == .visible }.count }
    var nearbyJobCount: Int { jobs.values.filter { $0.location == .nearby }.count }
    var idleJobCount: Int { jobs.values.filter { $0.location == .idle }.count }

    func reset(items: [MediaItem], records: [String: IndexRecord] = [:]) {
        generation += 1
        for task in runningTasks.values { task.cancel() }
        runningTasks.removeAll()
        jobs.removeAll()
        visibleIDs.removeAll()
        running.removeAll()
        idleArmed = false
        activeCount = 0
        submittedCount = 0
        pendingCount = 0
        blockedStages.removeAll()
        stageAttempts.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        heldForRetry.removeAll()
        doneCover.removeAll()
        doneSprite.removeAll()
        for (id, rec) in records {
            remember(rec, id: id)
        }
        orderedIDs = items.map(\.id)
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        try? ThumbnailStore.prepareDirectories()
    }

    /// 目录有增减时接上新条目、拿掉消失的。不换代、不把已有条目重新入队。
    func sync(items: [MediaItem], records: [String: IndexRecord] = [:]) {
        let newIDs = Set(items.map(\.id))
        let oldIDs = Set(orderedIDs)

        for id in oldIDs where !newIDs.contains(id) {
            runningTasks[id]?.cancel()
            runningTasks.removeValue(forKey: id)
            jobs.removeValue(forKey: id)
            visibleIDs.remove(id)
            for stage in [IndexingPipeline.Stage.cover, .sprite] {
                let key = Self.stageKey(id, stage)
                blockedStages.remove(key)
                stageAttempts.removeValue(forKey: key)
            }
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            heldForRetry.remove(id)
            doneCover.remove(id)
            doneSprite.remove(id)
        }

        for item in items where !oldIDs.contains(item.id) {
            if let rec = records[item.id] {
                remember(rec, id: item.id)
            }
        }

        orderedIDs = items.map(\.id)
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        pendingCount = jobs.count
        refreshWindow()
    }

    func appear(id: String) {
        visibleIDs.insert(id)
        refreshWindow()
    }

    func disappear(id: String) {
        visibleIDs.remove(id)
        refreshWindow()
    }

    /// 空闲时才把剩余项入队。打开目录的当时不要调用。
    func armIdleFill() {
        guard !idleArmed else { return }
        idleArmed = true
        refreshWindow()
    }

    // MARK: - 窗口

    private func refreshWindow() {
        let indices = orderedIDs.indices.filter { visibleIDs.contains(orderedIDs[$0]) }
        let lo = indices.min()
        let hi = indices.max()
        let page: Int
        if let lo, let hi {
            page = max(hi - lo + 1, 10)
        } else {
            page = 10
        }
        let nearLo: Int
        let nearHi: Int
        if let lo, let hi {
            nearLo = max(0, lo - page)
            nearHi = min(orderedIDs.count - 1, hi + page)
        } else {
            nearLo = 0
            nearHi = -1
        }

        var next: [String: Job] = [:]
        for (i, id) in orderedIDs.enumerated() {
            let location: Location?
            if let lo, let hi, i >= lo, i <= hi {
                location = .visible
            } else if nearHi >= nearLo, i >= nearLo, i <= nearHi {
                location = .nearby
            } else if idleArmed {
                location = .idle
            } else {
                location = nil
            }

            guard let location, let item = itemsByID[id] else { continue }
            let wantsCover = !doneCover.contains(id)
                && !blockedStages.contains(Self.stageKey(id, .cover))
            let wantsSprite = !doneSprite.contains(id)
                && !blockedStages.contains(Self.stageKey(id, .sprite))
            guard wantsCover || wantsSprite else { continue }

            if var existing = jobs[id] {
                existing.location = location
                next[id] = existing
            } else {
                next[id] = Job(
                    item: item,
                    location: location,
                    wantsCover: wantsCover,
                    wantsSprite: wantsSprite
                )
            }
        }

        // 正在跑的不要从字典里拿掉，否则 finish 对不上
        for digest in running {
            if next[digest] == nil, let job = jobs[digest] {
                var kept = job
                kept.location = .idle
                next[digest] = kept
            }
        }

        jobs = next
        pendingCount = jobs.count
        pump()
    }

    // MARK: - 泵

    private func pump() {
        guard enableProcessing else { return }
        let cap = IndexingPipeline.maxConcurrent
        while running.count < cap {
            guard let pick = pickNext() else { break }
            running.insert(pick.digest)
            activeCount = running.count
            submittedCount += 1
            pendingCount = jobs.count
            let item = pick.item
            let stage = pick.stage
            let fraction = startFraction
            let gen = generation
            let index = self.index
            let task = Task.detached { [weak self] in
                let outcome = await IndexingPipeline.processOne(
                    item: item, index: index, stage: stage, startFraction: fraction
                )
                let record = await index.record(for: item.key)
                try? await index.saveIfNeeded()
                await self?.finish(
                    digest: item.id, stage: stage, outcome: outcome, record: record, generation: gen
                )
            }
            runningTasks[pick.digest] = task
        }
        if running.isEmpty, jobs.values.allSatisfy({ !$0.wantsCover && !$0.wantsSprite }) {
            Task { try? await index.save() }
        }
    }

    private func pickNext() -> (item: MediaItem, stage: IndexingPipeline.Stage, digest: String)? {
        var best: Job?
        var bestScore = Int.max
        for job in jobs.values {
            guard !running.contains(job.digest) else { continue }
            // 刚失败的这一轮先让开，别和「失败—立刻重投」绕成空转。
            guard !heldForRetry.contains(job.digest) else { continue }
            guard job.wantsCover || job.wantsSprite else { continue }
            let s = score(job)
            if s < bestScore {
                bestScore = s
                best = job
            }
        }
        guard let best else { return nil }
        let stage: IndexingPipeline.Stage = best.wantsCover ? .cover : .sprite
        return (best.item, stage, best.digest)
    }

    /// 可见封面 → 邻近封面 → 可见精灵图 → 邻近精灵图 → 空闲封面 → 空闲精灵图
    private func score(_ job: Job) -> Int {
        let loc = job.location.rawValue
        let stage = job.wantsCover ? 0 : 1
        if loc <= 1 {
            return stage * 2 + loc
        }
        return 4 + stage
    }

    private func finish(
        digest: String,
        stage: IndexingPipeline.Stage,
        outcome: IndexingPipeline.Outcome,
        record: IndexRecord?,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        running.remove(digest)
        runningTasks.removeValue(forKey: digest)
        activeCount = running.count
        if let record {
            onRecord?(record)
        }
        switch outcome {
        case .failed:
            let key = Self.stageKey(digest, stage)
            let recorded = record?.failureRecord(for: stage)
            let attempts = max(recorded?.attempts ?? 0, (stageAttempts[key] ?? 0) + 1)
            stageAttempts[key] = attempts
            // 类别看落库的记录，次数取「落库的」和「本轮实际跑的」里更大的那个：
            // 索引万一没写上，也不会在这里一直重投同一条。
            let retryable = (recorded?.kind.isRetryable ?? true)
                && attempts < FailureRecord.maxAttempts
            if retryable {
                // 这一阶段仍然留在本轮队列里，等 retryDelay 过去自己排回来。
                // 早先是直接摘掉、等条目重新滚进可见窗口才有第二次机会——可用户
                // 正盯着的恰恰就是这一条，不滚走再滚回来就永远等不到重试。
                scheduleRetry(digest: digest)
            } else {
                // unsupported，或者已经试满 maxAttempts 次：这一阶段到此为止。
                blockedStages.insert(key)
                clearStage(stage, of: digest)
            }
        case .cancelled:
            // 取消不是素材失败。先移出本轮队列，之后再次进入可见窗口时可重新入队。
            jobs.removeValue(forKey: digest)
        case .succeeded, .skipped:
            if stage == .cover { doneCover.insert(digest) }
            if stage == .sprite { doneSprite.insert(digest) }
            clearStage(stage, of: digest)
        }
        pendingCount = jobs.count
        pump()
    }

    /// 把条目压住一小会儿再放回候选集合。
    ///
    /// 次数上限由 `stageAttempts` / 落库的 `FailureRecord` 一起管，试满就走
    /// `blockedStages`，因此这里不会无限重投。
    private func scheduleRetry(digest: String) {
        heldForRetry.insert(digest)
        retryTasks[digest]?.cancel()
        let gen = generation
        let delay = max(0, retryDelay)
        retryTasks[digest] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.releaseRetry(digest: digest, generation: gen)
        }
    }

    private func releaseRetry(digest: String, generation: Int) {
        retryTasks.removeValue(forKey: digest)
        guard generation == self.generation else { return }
        guard heldForRetry.remove(digest) != nil else { return }
        pump()
    }

    private static func stageKey(_ digest: String, _ stage: IndexingPipeline.Stage) -> String {
        switch stage {
        case .cover: return digest + "#cover"
        case .sprite: return digest + "#sprite"
        }
    }

    /// 把某个阶段从当前这一轮的作业里摘掉，两个阶段都没得做了才丢掉整条。
    private func clearStage(_ stage: IndexingPipeline.Stage, of digest: String) {
        guard var job = jobs[digest] else { return }
        switch stage {
        case .cover: job.wantsCover = false
        case .sprite: job.wantsSprite = false
        }
        if !job.wantsCover && !job.wantsSprite {
            jobs.removeValue(forKey: digest)
        } else {
            jobs[digest] = job
        }
    }

    private func remember(_ rec: IndexRecord, id: String) {
        // 只有判了死刑的阶段才预先拉黑；可重试的照常排队。
        if let failure = rec.coverFailure, !failure.isRetryable {
            blockedStages.insert(Self.stageKey(id, .cover))
        }
        if let failure = rec.spriteFailure, !failure.isRetryable {
            blockedStages.insert(Self.stageKey(id, .sprite))
        }
        if rec.hasCover, ThumbnailStore.hasCover(digest: id) {
            doneCover.insert(id)
        }
        if rec.hasSprite, ThumbnailStore.hasSprite(digest: id) {
            doneSprite.insert(id)
        }
    }

    private struct Job {
        let item: MediaItem
        var location: Location
        var wantsCover: Bool
        var wantsSprite: Bool
        var digest: String { item.id }
    }
}
