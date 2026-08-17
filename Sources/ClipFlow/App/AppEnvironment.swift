import AppKit
import Foundation
import Observation

enum BrowserSort: String, CaseIterable, Identifiable {
    case name
    case duration
    case resolution
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .duration: return "时长"
        case .resolution: return "分辨率"
        case .date: return "日期"
        }
    }
}

/// 应用级共享对象：播放、索引、浏览状态都从这里拿。
@MainActor
@Observable
final class AppEnvironment {
    private enum Pref {
        static let lastFolder = "lastFolderPath"
        static let sidebarWidth = "sidebarWidth"
        static let browserOnRight = "browserOnRight"
        static let showsGrid = "showsGrid"
        static let sort = "browserSort"
        static let sortAscending = "browserSortAscending"
    }

    let playback = PlaybackController()
    let index: MediaIndex
    let thumbnails: ThumbnailQueue

    var items: [MediaItem] = []
    var selectedID: String?
    var records: [String: IndexRecord] = [:]
    var folderURL: URL?
    var skippedCount = 0
    var isBrowserVisible = true
    var browserOnRight = false {
        didSet { UserDefaults.standard.set(browserOnRight, forKey: Pref.browserOnRight) }
    }
    var sidebarWidth: Double = 320 {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: Pref.sidebarWidth) }
    }
    var shouldScrollToSelection = false
    var showsGrid = false {
        didSet { UserDefaults.standard.set(showsGrid, forKey: Pref.showsGrid) }
    }
    var searchText = ""
    var sort: BrowserSort = .name {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: Pref.sort)
            thumbnails.sync(items: sortedItems, records: records)
        }
    }
    var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: Pref.sortAscending)
            thumbnails.sync(items: sortedItems, records: records)
        }
    }

    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored private var folderGeneration = 0
    @ObservationIgnored private var didAttemptRestore = false

    var selectedItem: MediaItem? {
        items.first { $0.id == selectedID }
    }

    /// 当前排序下的全部条目，搜索不影响抽帧队列。
    var sortedItems: [MediaItem] {
        sortItems(items)
    }

    /// 列表 / 网格 / 上一个下一个用这一份。
    var displayedItems: [MediaItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sortedItems
        if q.isEmpty { return source }
        return source.filter { $0.name.localizedStandardContains(q) }
    }

    init() {
        let index = MediaIndex()
        self.index = index
        let startFraction = (UserDefaults.standard.object(forKey: "coverStartFraction") as? Double)
            ?? CoverPicker.defaultStartFraction
        let queue = ThumbnailQueue(index: index, startFraction: startFraction)
        self.thumbnails = queue
        queue.onRecord = { [weak self] record in
            self?.records[record.key.digest] = record
        }
        playback.onPlaybackEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Pref.sidebarWidth) != nil {
            sidebarWidth = min(max(defaults.double(forKey: Pref.sidebarWidth), 200), 560)
        }
        browserOnRight = defaults.bool(forKey: Pref.browserOnRight)
        showsGrid = defaults.bool(forKey: Pref.showsGrid)
        if let raw = defaults.string(forKey: Pref.sort), let saved = BrowserSort(rawValue: raw) {
            sort = saved
        }
        if defaults.object(forKey: Pref.sortAscending) != nil {
            sortAscending = defaults.bool(forKey: Pref.sortAscending)
        } else {
            sortAscending = (sort == .name)
        }
        folderWatcher.onDebouncedChange = { [weak self] in
            self?.handleFolderChange()
        }
        Task {
            await index.load()
            await self.restoreLastFolderIfNeeded()
        }
    }

    // MARK: - 目录

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要浏览的视频文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    func openFolder(_ url: URL) async {
        folderGeneration += 1
        let gen = folderGeneration
        folderWatcher.stop()

        let path = url.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            guard gen == folderGeneration else { return }
            clearFolderQuietly(forgetSavedPath: false)
            return
        }

        folderURL = url
        applyWindowChrome()
        UserDefaults.standard.set(path, forKey: Pref.lastFolder)

        thumbnails.reset(items: [])
        playback.pause()
        selectedID = nil
        records = [:]

        let scanned = url
        let result = await Task.detached {
            MediaScanner.scan(root: scanned)
        }.value
        guard gen == folderGeneration else { return }

        items = result.items
        skippedCount = result.skippedCount

        await index.load()
        var recs: [String: IndexRecord] = [:]
        for item in items {
            if let record = await index.record(for: item.key) {
                recs[item.id] = record
            }
        }
        records = recs
        thumbnails.reset(items: sortedItems, records: recs)

        if let first = displayedItems.first {
            select(first)
        }

        folderWatcher.start(path: path)

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard gen == folderGeneration else { return }
            thumbnails.armIdleFill()
        }
    }

    func restoreLastFolderIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard folderURL == nil else { return }
        guard let path = UserDefaults.standard.string(forKey: Pref.lastFolder), !path.isEmpty else {
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        await openFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

    func applyWindowChrome() {
        guard let window = NSApp.keyWindow else { return }
        if let url = folderURL {
            window.representedURL = url
            window.title = url.lastPathComponent
        } else {
            window.representedURL = nil
            window.title = "ClipFlow"
        }
    }

    // MARK: - 目录变化

    private func handleFolderChange() {
        Task { await refreshOpenFolder() }
    }

    private func refreshOpenFolder() async {
        guard let url = folderURL else { return }
        let gen = folderGeneration
        let path = url.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            guard gen == folderGeneration else { return }
            clearFolderQuietly(forgetSavedPath: false)
            return
        }

        let scanned = url
        let result = await Task.detached {
            MediaScanner.scan(root: scanned)
        }.value
        guard gen == folderGeneration,
              folderURL?.path(percentEncoded: false) == url.path(percentEncoded: false)
        else { return }
        await applyIncrementalScan(result)
    }

    private func applyIncrementalScan(_ result: MediaScanner.Result) async {
        let oldIDs = Set(items.map(\.id))
        let newIDs = Set(result.items.map(\.id))
        if oldIDs == newIDs, skippedCount == result.skippedCount {
            return
        }

        let added = result.items.filter { !oldIDs.contains($0.id) }
        var recs = records
        for id in oldIDs where !newIDs.contains(id) {
            recs.removeValue(forKey: id)
        }
        for item in added {
            if let record = await index.record(for: item.key) {
                recs[item.id] = record
            }
        }

        let wasEmpty = items.isEmpty
        let previousSelected = selectedID
        items = result.items
        skippedCount = result.skippedCount
        records = recs
        thumbnails.sync(items: sortedItems, records: recs)

        if let previousSelected, newIDs.contains(previousSelected) {
            return
        }
        if previousSelected != nil {
            playback.pause()
            selectedID = nil
        }
        if wasEmpty, let first = displayedItems.first {
            select(first)
        }
    }

    private func clearFolderQuietly(forgetSavedPath: Bool) {
        folderWatcher.stop()
        folderURL = nil
        items = []
        records = [:]
        selectedID = nil
        skippedCount = 0
        searchText = ""
        thumbnails.reset(items: [])
        playback.pause()
        if forgetSavedPath {
            UserDefaults.standard.removeObject(forKey: Pref.lastFolder)
        }
        applyWindowChrome()
    }

    // MARK: - 排序

    private func sortItems(_ list: [MediaItem]) -> [MediaItem] {
        list.sorted { lhs, rhs in
            switch sort {
            case .name:
                return compareName(lhs.name, rhs.name)
            case .duration:
                return compareOptional(
                    records[lhs.id]?.duration, records[rhs.id]?.duration, lhs, rhs
                )
            case .resolution:
                return compareOptional(pixelCount(lhs), pixelCount(rhs), lhs, rhs)
            case .date:
                if lhs.key.modified != rhs.key.modified {
                    return sortAscending
                        ? lhs.key.modified < rhs.key.modified
                        : lhs.key.modified > rhs.key.modified
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func pixelCount(_ item: MediaItem) -> Double? {
        guard let width = records[item.id]?.width, let height = records[item.id]?.height else {
            return nil
        }
        return Double(width * height)
    }

    /// 名称无论正反都走自然序，避免 10.mp4 排到 9.mp4 前面。
    private func compareName(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending:
            return sortAscending
        case .orderedDescending:
            return !sortAscending
        case .orderedSame:
            return false
        }
    }

    /// 缺元数据的条目始终靠后；同值再用名称自然序。
    private func compareOptional(
        _ a: Double?,
        _ b: Double?,
        _ lhs: MediaItem,
        _ rhs: MediaItem
    ) -> Bool {
        switch (a, b) {
        case let (l?, r?):
            if l != r {
                return sortAscending ? l < r : l > r
            }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            break
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - 选中即播

    func select(_ item: MediaItem, scroll: Bool = false) {
        if selectedID == item.id {
            if playback.isPaused { playback.play() }
            return
        }
        selectedID = item.id
        shouldScrollToSelection = scroll
        playback.loadFile(item.url)
    }

    func selectOffset(_ delta: Int, wrap: Bool) {
        let list = displayedItems
        guard !list.isEmpty else { return }
        let next: Int
        if let current = list.firstIndex(where: { $0.id == selectedID }) {
            if wrap {
                next = (current + delta + list.count) % list.count
            } else {
                let raw = current + delta
                guard list.indices.contains(raw) else { return }
                next = raw
            }
        } else {
            next = delta >= 0 ? 0 : list.count - 1
        }
        select(list[next], scroll: true)
    }

    /// 播完由播放内核通知。单个循环在控制器里处理；列表循环回头；关闭则自动下一个但不回头。
    private func handlePlaybackEnded() {
        switch playback.loopMode {
        case .single:
            break
        case .playlist:
            selectOffset(1, wrap: true)
        case .off:
            selectOffset(1, wrap: false)
        }
    }

    // MARK: - C 键封面

    /// 把当前播放帧写成封面。走 AVFoundation，不用 mpv screenshot。
    func captureCoverFromCurrentFrame() {
        guard let item = selectedItem else { return }
        var seconds = playback.currentPlaybackTime() ?? playback.currentTime
        guard seconds.isFinite, seconds >= 0 else { return }
        if playback.duration > 0 {
            seconds = min(seconds, max(playback.duration - 0.04, 0))
        }
        Task { await applyManualCover(item: item, seconds: seconds) }
    }

    private func applyManualCover(item: MediaItem, seconds: Double) async {
        do {
            let output = try await SpriteGenerator.generateCover(url: item.url, at: seconds)
            try ThumbnailStore.writeCover(output.coverJPEG, digest: item.key.digest)
            var record = await index.record(for: item.key) ?? IndexRecord(key: item.key)
            if record.duration == nil, playback.duration > 0 {
                record.duration = playback.duration
            }
            record.coverTime = output.coverTime
            record.manualCoverTime = output.coverTime
            record.coverIsFallback = false
            record.failure = nil
            await index.upsert(record)
            try? await index.save()
            records[item.id] = record
        } catch {
            NSLog("封面抓取失败: \(error)")
        }
    }
}
