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

    private(set) var activeCount = 0
    private(set) var submittedCount = 0
    private(set) var pendingCount = 0

    @ObservationIgnored private var itemsByID: [String: MediaItem] = [:]
    @ObservationIgnored private var orderedIDs: [String] = []
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var failedIDs: Set<String> = []
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
        jobs.removeAll()
        visibleIDs.removeAll()
        running.removeAll()
        idleArmed = false
        activeCount = 0
        submittedCount = 0
        pendingCount = 0
        failedIDs.removeAll()
        doneCover.removeAll()
        doneSprite.removeAll()
        for (id, rec) in records {
            if rec.failure != nil {
                failedIDs.insert(id)
                continue
            }
            if rec.hasCover, ThumbnailStore.hasCover(digest: id) {
                doneCover.insert(id)
            }
            if rec.hasSprite, ThumbnailStore.hasSprite(digest: id) {
                doneSprite.insert(id)
            }
        }
        orderedIDs = items.map(\.id)
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        try? ThumbnailStore.prepareDirectories()
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
            if failedIDs.contains(id) { continue }
            let wantsCover = !doneCover.contains(id)
            let wantsSprite = !doneSprite.contains(id)
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
            Task.detached { [weak self] in
                let outcome = await IndexingPipeline.processOne(
                    item: item, index: index, stage: stage, startFraction: fraction
                )
                let record = await index.record(for: item.key)
                try? await index.saveIfNeeded()
                await self?.finish(
                    digest: item.id, stage: stage, outcome: outcome, record: record, generation: gen
                )
            }
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
        activeCount = running.count
        if let record {
            onRecord?(record)
        }
        switch outcome {
        case .failed:
            failedIDs.insert(digest)
            jobs.removeValue(forKey: digest)
        case .succeeded, .skipped:
            if stage == .cover { doneCover.insert(digest) }
            if stage == .sprite { doneSprite.insert(digest) }
            if var job = jobs[digest] {
                if stage == .cover { job.wantsCover = false }
                if stage == .sprite { job.wantsSprite = false }
                if !job.wantsCover && !job.wantsSprite {
                    jobs.removeValue(forKey: digest)
                } else {
                    jobs[digest] = job
                }
            }
        }
        pendingCount = jobs.count
        pump()
    }

    private struct Job {
        let item: MediaItem
        var location: Location
        var wantsCover: Bool
        var wantsSprite: Bool
        var digest: String { item.id }
    }
}
