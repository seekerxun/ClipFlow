import Foundation

/// 扫描之后的加工流水线：探元数据 → 抽帧生成精灵图 → 选封面 → 落库。
///
/// 并发上限刻意压得很低。视频解码是内存大户，把一千个文件一次性排进队列
/// 会直接把内存打爆；而且真正决定「首屏出图有多快」的是优先级，不是并发数。
enum IndexingPipeline {

    /// 流水线分两段跑。
    ///
    /// 拆开是因为两者成本差一个数量级：封面通常只解一帧，精灵图要解 24 帧。
    /// 全都挤在一起做的话，用户得等整个目录的精灵图都生成完才能看到第一屏。
    enum Stage: Sendable {
        /// 只出封面，格子立刻能填满。
        case cover
        /// 完整精灵图，供悬停扫过与进度条预览，可以在后台慢慢补。
        case sprite
    }

    static var maxConcurrent: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    struct Progress: Sendable {
        var done = 0
        var total = 0
        var succeeded = 0
        var failed = 0
        var skipped = 0
    }

    /// 处理一批条目。
    ///
    /// - Parameter onProgress: 每完成一个回调一次，调用方据此刷新界面。
    @discardableResult
    static func process(
        items: [MediaItem],
        index: MediaIndex,
        stage: Stage,
        startFraction: Double = CoverPicker.defaultStartFraction,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Progress {

        try? ThumbnailStore.prepareDirectories()

        var progress = Progress(total: items.count)
        var cursor = 0

        await withTaskGroup(of: Outcome.self) { group in
            func addNext() {
                while cursor < items.count {
                    let item = items[cursor]
                    cursor += 1
                    group.addTask {
                        await processOne(
                            item: item, index: index, stage: stage, startFraction: startFraction
                        )
                    }
                    return
                }
            }

            for _ in 0..<min(maxConcurrent, items.count) { addNext() }

            while let outcome = await group.next() {
                progress.done += 1
                switch outcome {
                case .succeeded: progress.succeeded += 1
                case .failed: progress.failed += 1
                case .skipped, .cancelled: progress.skipped += 1
                }
                onProgress?(progress)
                try? await index.saveIfNeeded()
                addNext()
            }
        }

        try? await index.save()
        return progress
    }

    enum Outcome: Sendable {
        case succeeded
        case failed
        case skipped
        /// 用户滚离、切换目录或关闭窗口导致的取消，不属于素材失败，绝不落库。
        case cancelled
    }

    /// 处理单条。界面的可见队列走这条，不要把整目录丢进 `process`。
    @discardableResult
    static func processOne(
        item: MediaItem,
        index: MediaIndex,
        stage: Stage,
        startFraction: Double = CoverPicker.defaultStartFraction
    ) async -> Outcome {

        if Task.isCancelled { return .cancelled }
        try? ThumbnailStore.prepareDirectories()
        guard await index.needsWork(for: item, stage: stage) else { return .skipped }

        var record = await index.record(for: item.key) ?? IndexRecord(key: item.key)

        do {
            try Task.checkCancellation()
            // 元数据可能上一阶段已经拿到过，没有才探
            let info: MediaProbe.Info
            if let duration = record.duration, let w = record.width, let h = record.height {
                info = MediaProbe.Info(duration: duration, width: w, height: h)
            } else {
                info = try await MediaProbe.probe(item.url)
                try Task.checkCancellation()
                record.duration = info.duration
                record.width = info.width
                record.height = info.height
            }

            switch stage {
            case .cover:
                if let manual = record.manualCoverTime {
                    let cover = try await SpriteGenerator.generateCoverWithFallback(
                        url: item.url, at: manual
                    )
                    try ThumbnailStore.writeCover(cover.coverJPEG, digest: item.key.digest)
                    record.coverTime = cover.coverTime
                    record.coverIsFallback = false
                    record.manualCoverTime = manual
                } else {
                    let cover = try await SpriteGenerator.generateCoverWithFallback(
                        url: item.url, info: info, startFraction: startFraction
                    )
                    if let latest = await index.record(for: item.key),
                       latest.manualCoverTime != nil
                    {
                        return .succeeded
                    }
                    try ThumbnailStore.writeCover(cover.coverJPEG, digest: item.key.digest)
                    record.coverTime = cover.coverTime
                    record.coverIsFallback = cover.isFallback
                }

            case .sprite:
                let sprite = try await SpriteGenerator.generateWithFallback(
                    url: item.url, info: info
                )
                try ThumbnailStore.writeSprite(sprite.spriteJPEG, digest: item.key.digest)
                record.spriteTimestamps = sprite.timestamps
                record.tileWidth = sprite.tileWidth
                record.tileHeight = sprite.tileHeight
            }

            // 只清本阶段的失败。精灵图成功不代表封面的问题也没了，反之亦然。
            record.setFailure(nil, for: stage)
            await index.upsert(record)
            return .succeeded

        } catch is CancellationError {
            // 用户滚离、切目录、关窗都会走到这里。这不是素材的问题，绝不落库，
            // 否则正常文件会被自己的滚动操作拉黑。
            return .cancelled
        } catch {
            record.setFailure(
                FailureRecord.next(
                    after: record.failureRecord(for: stage),
                    reason: String(describing: error),
                    kind: failureKind(for: error)
                ),
                for: stage
            )
            await index.upsert(record)
            return .failed
        }
    }

    /// 把底层报错归到失败类别上。类别决定还要不要重试。
    ///
    /// 关键是别把超时当成坏文件：超时只说明当时机器忙或者素材在慢盘上，
    /// 换个时候多半就过了。以前所有报错一视同仁，一次超时就永久跳过。
    static func failureKind(for error: Error) -> FailureKind {
        if let runner = error as? ProcessRunner.RunnerError, case .timedOut = runner {
            return .timeout
        }
        if let probe = error as? MediaProbe.ProbeError {
            switch probe {
            case .timedOut:
                return .timeout
            case .noVideoTrack:
                // 没有视频轨的文件再试一百次也出不来画面
                return .unsupported
            case .unreadable:
                return .decodeError
            }
        }
        if let ffmpeg = error as? FFmpegSpriteGenerator.GenerateError {
            switch ffmpeg {
            case .invalidImage, .blankFrame:
                // 纯黑帧多半是解码落点没赶上关键帧，换个时间点重来常常就有画面
                return .invalidImage
            case .noFrames, .encodeFailed:
                return .decodeError
            }
        }
        return .decodeError
    }
}
