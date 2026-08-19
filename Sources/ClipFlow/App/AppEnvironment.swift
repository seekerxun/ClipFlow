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
    var isSearchVisible = false
    var searchFocusRequest = 0
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

    /// 本列表所在的那扇窗口。打开文件时要把它叫到最前面，否则文件会落在后面一扇。
    @ObservationIgnored weak var hostWindow: NSWindow?

    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored private var folderGeneration = 0
    @ObservationIgnored private var folderRoots: [URL] = []
    @ObservationIgnored private var looseFiles: [URL] = []
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var frameTimelineTask: Task<Void, Never>?

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
        // 索引全应用共用一份，不跟着窗口走。见 `MediaIndex.shared`。
        let index = MediaIndex.shared
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
        playback.onFileChanged = { [weak self] _ in
            self?.loadFrameTimelineIfNeeded()
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
        defaults.removeObject(forKey: "lastFolderPath")
        defaults.removeObject(forKey: "lastFolderPaths")
        defaults.removeObject(forKey: "lastFilePaths")
        Task {
            await index.load()
        }
    }

    // MARK: - 加入列表

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "打开"
        panel.message = "选择要加入列表的视频文件夹"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        Task { await addURLs(urls) }
    }

    /// 把拖入或打开的来源加入当前列表。不清空已有条目；同一路径不加第二次。
    func addURLs(_ urls: [URL]) async {
        let previous = sourceTask
        let task = Task { @MainActor in
            await previous?.value
            await self.performAdd(urls)
        }
        sourceTask = task
        await task.value
    }

    private func performAdd(_ urls: [URL]) async {
        folderGeneration += 1
        let gen = folderGeneration
        let result = await Task.detached {
            MediaScanner.collect(from: urls)
        }.value
        recordSources(from: urls)
        await appendItems(result.items)
        startWatchingCurrentRoots()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard gen == folderGeneration else { return }
            thumbnails.armIdleFill()
        }
    }

    func applyWindowChrome() {
        // 窗口标题由各窗口按当前播放文件更新，这里不再写死 ClipFlow。
    }

    /// 搜索默认不占界面；Cmd+F 或搜索按钮进入后，由视图响应请求并取得焦点。
    func showSearch() {
        isBrowserVisible = true
        isSearchVisible = true
        searchFocusRequest &+= 1
    }

    func hideSearch() {
        searchText = ""
        isSearchVisible = false
    }

    private func recordSources(from urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            let path = url.path(percentEncoded: false)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
                if values?.isPackage == true { continue }
                if folderRoots.contains(where: { $0.path(percentEncoded: false) == path }) { continue }
                folderRoots.append(URL(fileURLWithPath: path, isDirectory: true))
            } else if MediaScanner.isVideoFile(url) {
                if looseFiles.contains(where: { $0.path(percentEncoded: false) == path }) { continue }
                looseFiles.append(URL(fileURLWithPath: path))
            }
        }
    }

    private func startWatchingCurrentRoots() {
        folderWatcher.start(paths: folderRoots.map { $0.path(percentEncoded: false) })
    }

    private func appendItems(_ newItems: [MediaItem]) async {
        let existingPaths = Set(items.map(\.key.path))
        let added = newItems.filter { !existingPaths.contains($0.key.path) }
        guard !added.isEmpty else { return }

        var recs = records
        for item in added {
            if let record = await index.record(for: item.key) {
                recs[item.id] = record
            }
        }

        let wasEmpty = items.isEmpty
        items.append(contentsOf: added)
        records = recs
        thumbnails.sync(items: sortedItems, records: recs)

        if wasEmpty, let first = displayedItems.first {
            select(first)
        }
    }

    // MARK: - 目录变化

    private func handleFolderChange() {
        let previous = sourceTask
        sourceTask = Task { @MainActor in
            await previous?.value
            await self.refreshSources()
        }
    }

    private func refreshSources() async {
        let roots = folderRoots
        let files = looseFiles
        let result = await Task.detached {
            MediaScanner.collect(from: roots + files)
        }.value

        folderRoots = roots.filter { Self.isExistingDirectory($0) }
        looseFiles = files.filter { Self.isExistingFile($0) }
        await applyIncrementalScan(result)
        startWatchingCurrentRoots()
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

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDir
        ) && isDir.boolValue
    }

    private static func isExistingFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDir
        ) && !isDir.boolValue
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

    // MARK: - 逐帧

    /// 逐帧模式开关。开的时候顺手把当前文件的逐帧时间表读进来。
    func toggleFrameStepMode() {
        playback.toggleFrameStepMode()
        loadFrameTimelineIfNeeded()
    }

    /// 逐帧模式下读一次当前文件每一帧的时间。关着模式、或者已经读到了就不读。
    ///
    /// 放在这里而不是播放控制器里，是因为读表要起后台任务，而这个类本来就在主线程上。
    private func loadFrameTimelineIfNeeded() {
        frameTimelineTask?.cancel()
        guard playback.isFrameStepMode,
              playback.frameTimeline == nil,
              let url = playback.loadedURL
        else { return }
        frameTimelineTask = Task { @MainActor in
            let timeline = try? await FrameTimeline.load(url)
            guard !Task.isCancelled else { return }
            playback.applyFrameTimeline(timeline, for: url)
        }
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

    // MARK: - B 键封面

    /// 把当前播放帧写成封面。优先走 AVFoundation，不支持时回退 ffmpeg。
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
            let output = try await SpriteGenerator.generateCoverWithFallback(
                url: item.url, at: seconds
            )
            try ThumbnailStore.writeCover(output.coverJPEG, digest: item.key.digest)
            var record = await index.record(for: item.key) ?? IndexRecord(key: item.key)
            if record.duration == nil, playback.duration > 0 {
                record.duration = playback.duration
            }
            record.coverTime = output.coverTime
            record.manualCoverTime = output.coverTime
            record.coverIsFallback = false
            // 用户亲手指定了封面，等于宣告这个文件没问题：两个阶段的失败一起清，
            // 这是卡住时唯一的人工解锁通道。
            record.coverFailure = nil
            record.spriteFailure = nil
            await index.upsert(record)
            try? await index.save()
            records[item.id] = record
        } catch {
            NSLog("封面抓取失败: \(error)")
        }
    }
}
