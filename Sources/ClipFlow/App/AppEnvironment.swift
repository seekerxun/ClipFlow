import AppKit
import Foundation
import Observation

/// 应用级共享对象：播放、索引、浏览状态都从这里拿。
@MainActor
@Observable
final class AppEnvironment {
    let playback = PlaybackController()
    let index: MediaIndex
    let thumbnails: ThumbnailQueue

    var items: [MediaItem] = []
    var selectedID: String?
    var records: [String: IndexRecord] = [:]
    var folderURL: URL?
    var skippedCount = 0
    var isBrowserVisible = true
    var browserOnRight = false
    var sidebarWidth: Double = 320
    var shouldScrollToSelection = false

    var selectedItem: MediaItem? {
        items.first { $0.id == selectedID }
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
        Task { await index.load() }
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
        folderURL = url
        NSApp.keyWindow?.representedURL = url
        NSApp.keyWindow?.title = url.lastPathComponent

        thumbnails.reset(items: [])
        playback.pause()
        selectedID = nil
        records = [:]

        let result = MediaScanner.scan(root: url)
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
        thumbnails.reset(items: items, records: recs)

        if let first = items.first {
            select(first)
        }

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard folderURL == url else { return }
            thumbnails.armIdleFill()
        }
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
        guard !items.isEmpty else { return }
        let current = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next: Int
        if wrap {
            next = (current + delta + items.count) % items.count
        } else {
            let raw = current + delta
            guard items.indices.contains(raw) else { return }
            next = raw
        }
        select(items[next], scroll: true)
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
