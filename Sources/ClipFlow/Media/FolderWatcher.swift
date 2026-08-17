import CoreServices
import Foundation

/// 盯着列表里涉及到的文件夹根（可多个，含子目录）。变化先合并再通知，避免每个事件都去扫一遍。
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var burstStartedAt: Date?

    /// 上次事件后再等这么久，期间又有事件就重新计时。
    private let debounceInterval: TimeInterval = 0.4
    /// 连着来事件时，最多这么久必须扫一次，避免大拷贝一直拖着不刷新。
    private let maxBurstInterval: TimeInterval = 2.0

    var onDebouncedChange: (() -> Void)?

    func start(paths: [String]) {
        stop()
        let unique = paths.filter { !$0.isEmpty }
        guard !unique.isEmpty else { return }
        let paths = unique as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        burstStartedAt = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    fileprivate func noteChange() {
        let now = Date()
        if burstStartedAt == nil {
            burstStartedAt = now
        }
        debounceWork?.cancel()
        let elapsed = now.timeIntervalSince(burstStartedAt ?? now)
        let delay = elapsed >= maxBurstInterval ? 0 : debounceInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.burstStartedAt = nil
            self.debounceWork = nil
            self.onDebouncedChange?()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private func folderWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    Unmanaged<FolderWatcher>.fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
        .noteChange()
}
