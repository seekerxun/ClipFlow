import Foundation

/// 命令行基准测试。
///
/// 用法：CLIPFLOW_BENCH=/path/to/dir ClipFlow.app/Contents/MacOS/ClipFlow
///
/// 存在的意义是让性能目标可验证，而不是靠「感觉挺快」。
/// 界面还没搭之前，这是唯一能拿真实素材量数据的手段。
enum Bench {

    static func runIfRequested() -> Bool {
        if ProcessInfo.processInfo.environment["CLIPFLOW_BENCH"] != nil {
            return runBench()
        }
        if let root = ProcessInfo.processInfo.environment["CLIPFLOW_QUEUE_CHECK"] {
            setvbuf(stdout, nil, _IONBF, 0)
            // ThumbnailQueue 在主线程；不能在主线程上 semaphore.wait，否则会自己卡死。
            Task { @MainActor in
                await runQueueCheck(root: root)
                exit(0)
            }
            RunLoop.main.run()
            return true
        }
        return false
    }

    private static func runBench() -> Bool {
        guard let root = ProcessInfo.processInfo.environment["CLIPFLOW_BENCH"] else {
            return false
        }
        setvbuf(stdout, nil, _IONBF, 0)

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await run(roots: root.split(separator: ":").map(String.init))
            semaphore.signal()
        }
        semaphore.wait()
        return true
    }

    private static func run(roots: [String]) async {
        print("=== ClipFlow 索引流水线基准 ===\n")
        print("并发上限：\(IndexingPipeline.maxConcurrent)（CPU \(ProcessInfo.processInfo.activeProcessorCount) 核）\n")

        // 用独立的索引文件，不污染正式使用的那份
        let benchIndex = FileManager.default.temporaryDirectory
            .appending(path: "clipflow-bench-index.json")
        try? FileManager.default.removeItem(at: benchIndex)
        let index = MediaIndex(fileURL: benchIndex)
        await index.load()

        // --- 扫描 ---
        var items: [MediaItem] = []
        var skipped = 0
        let scanStart = Date()
        for root in roots {
            let result = MediaScanner.scan(root: URL(filePath: root))
            items.append(contentsOf: result.items)
            skipped += result.skippedCount
        }
        let scanElapsed = Date().timeIntervalSince(scanStart)
        print(String(format: "扫描：%d 个视频，跳过 %d 个非视频文件，耗时 %.3fs",
                     items.count, skipped, scanElapsed))
        guard !items.isEmpty else { print("没有找到视频，结束。"); return }

        // --- 第一阶段：首屏封面 ---
        let firstScreenCount = min(40, items.count)
        let firstStart = Date()
        await IndexingPipeline.process(
            items: Array(items.prefix(firstScreenCount)), index: index, stage: .cover
        )
        let firstElapsed = Date().timeIntervalSince(firstStart)
        print(String(format: "首屏封面：前 %d 个，耗时 %.3fs（目标 < 1s）%@",
                     firstScreenCount, firstElapsed, firstElapsed < 1.0 ? "  ✅" : "  ❌"))

        // --- 第一阶段：全量封面 ---
        let coverStart = Date()
        let coverProgress = await IndexingPipeline.process(
            items: items, index: index, stage: .cover
        )
        let coverElapsed = Date().timeIntervalSince(coverStart)
        let coverPer500 = coverElapsed * 500 / Double(max(1, items.count))
        print(String(format: "全量封面：%d 个，成功 %d，失败 %d，耗时 %.1fs（每个 %.0fms）",
                     coverProgress.total, coverProgress.succeeded, coverProgress.failed,
                     coverElapsed, coverElapsed * 1000 / Double(max(1, items.count))))
        print(String(format: "         折合 500 个约 %.1fs（目标 < 30s）%@",
                     coverPer500, coverPer500 < 30 ? "  ✅" : "  ❌"))

        // --- 第二阶段：精灵图（后台补，不阻塞浏览）---
        let spriteStart = Date()
        var lastPrint = Date()
        let progress = await IndexingPipeline.process(
            items: items, index: index, stage: .sprite
        ) { p in
            if Date().timeIntervalSince(lastPrint) > 5 {
                lastPrint = Date()
                print(String(format: "  … %d/%d", p.done, p.total))
            }
        }
        let spriteElapsed = Date().timeIntervalSince(spriteStart)
        print(String(format: "\n精灵图：%d 个，成功 %d，失败 %d，耗时 %.1fs（每个 %.0fms）",
                     progress.total, progress.succeeded, progress.failed,
                     spriteElapsed, spriteElapsed * 1000 / Double(max(1, items.count))))
        print(String(format: "       折合 500 个约 %.1fs（后台进行，目标 < 60s）%@",
                     spriteElapsed * 500 / Double(max(1, items.count)),
                     spriteElapsed * 500 / Double(max(1, items.count)) < 60 ? "  ✅" : "  ❌"))

        // --- 产物 ---
        let usage = ThumbnailStore.diskUsage()
        print(String(format: "\n预览图占用 %.1f MB，平均每个 %.0f KB",
                     Double(usage) / 1_048_576, Double(usage) / 1024 / Double(max(1, items.count))))

        // --- 封面兜底比例 ---
        let records = await index.allRecords
        let fallbacks = records.filter { $0.coverIsFallback }.count
        let failures = records.filter { $0.failure != nil }
        print(String(format: "封面兜底（三个窗口都没有合格帧）：%d 个，占 %.1f%%",
                     fallbacks, Double(fallbacks) * 100 / Double(max(1, records.count))))

        if !failures.isEmpty {
            print("\n失败样例（最多 5 条）：")
            for record in failures.prefix(5) {
                print("  \((record.key.path as NSString).lastPathComponent) — \(record.failure?.reason ?? "")")
            }
        }
        print("\n=== 结束 ===")
    }

    /// 扫描真实目录并验证可见队列不会把全部文件一次性入队。
    /// 不抽帧、不改用户素材。
    @MainActor
    private static func runQueueCheck(root: String) async {
        print("=== ClipFlow 可见队列检查 ===\n")

        let benchIndex = FileManager.default.temporaryDirectory
            .appending(path: "clipflow-queue-check-index.json")
        try? FileManager.default.removeItem(at: benchIndex)
        let index = MediaIndex(fileURL: benchIndex)
        await index.load()

        let scanStart = Date()
        let result = MediaScanner.scan(root: URL(filePath: root))
        let scanElapsed = Date().timeIntervalSince(scanStart)
        print(String(
            format: "扫描：%d 个视频，跳过 %d 个非视频文件，耗时 %.3fs",
            result.items.count, result.skippedCount, scanElapsed
        ))
        guard !result.items.isEmpty else {
            print("没有找到视频，结束。")
            return
        }

        let queue = ThumbnailQueue(index: index)
        queue.enableProcessing = false
        queue.reset(items: result.items)

        let visibleCount = min(12, result.items.count)
        for item in result.items.prefix(visibleCount) {
            queue.appear(id: item.id)
        }

        let pending = queue.pendingCount
        print(String(
            format: "可见窗口入队：pending=%d visible=%d nearby=%d idle=%d 目录总数=%d",
            pending, queue.visibleJobCount, queue.nearbyJobCount, queue.idleJobCount,
            result.items.count
        ))
        print("submitted=\(queue.submittedCount) active=\(queue.activeCount) 上限=\(IndexingPipeline.maxConcurrent)")

        var ok = true
        if result.items.count > visibleCount * 3 {
            if pending >= result.items.count {
                print("❌ 打开时把全部文件入队了")
                ok = false
            } else if queue.idleJobCount > 0 {
                print("❌ 未开空闲补齐却有 idle 任务")
                ok = false
            } else {
                print("✅ 打开时未全量入队")
            }
        } else {
            print("（目录较小，跳过全量入队断言）")
        }

        if queue.submittedCount != 0 || queue.activeCount != 0 {
            print("❌ 检查模式不应真正提交抽帧")
            ok = false
        }

        queue.armIdleFill()
        print(String(
            format: "空闲补齐后：pending=%d idle=%d submitted=%d",
            queue.pendingCount, queue.idleJobCount, queue.submittedCount
        ))
        if queue.submittedCount != 0 {
            print("❌ 空闲补齐不应在检查模式提交抽帧")
            ok = false
        } else if result.items.count > visibleCount * 3, queue.idleJobCount == 0 {
            print("❌ 空闲补齐后没有剩余项")
            ok = false
        } else {
            print("✅ 空闲补齐只入队、未开 500 个 Task")
        }

        queue.reset(items: [])
        print(ok ? "\n=== 通过 ===" : "\n=== 未通过 ===")
        if !ok {
            exit(1)
        }
    }
}
