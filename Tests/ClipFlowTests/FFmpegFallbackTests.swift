import ImageIO
import XCTest
@testable import ClipFlow

final class FFmpegFallbackTests: XCTestCase {

    func testFFprobeAppliesRotationToDisplaySize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mp4")
        let rotated = directory.appending(path: "rotated.mp4")

        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            source.path(percentEncoded: false)
        ])
        try await runFFmpeg([
            "-display_rotation", "90",
            "-i", source.path(percentEncoded: false),
            "-c", "copy",
            rotated.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(rotated)
        XCTAssertEqual(info.width, 90)
        XCTAssertEqual(info.height, 160)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
    }

    func testSpriteHas24FramesAndMatchesSpec() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "sample.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
            "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            video.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(video)
        let cover = try await FFmpegSpriteGenerator.generateCover(url: video, info: info)
        let output = try await FFmpegSpriteGenerator.generate(url: video, info: info)
        let coverSource = CGImageSourceCreateWithData(cover.coverJPEG as CFData, nil)
        let coverImage = coverSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(coverImage?.width, SpriteSpec.coverSide)
        XCTAssertEqual(coverImage?.height, SpriteSpec.coverSide)
        XCTAssertGreaterThanOrEqual(cover.coverTime, 0)
        XCTAssertLessThanOrEqual(cover.coverTime, info.duration)
        XCTAssertEqual(output.timestamps.count, SpriteSpec.frameCount)
        XCTAssertEqual(output.tileWidth, SpriteSpec.maxTileDimension)
        XCTAssertEqual(output.tileHeight, 82)
        XCTAssertTrue(zip(output.timestamps, output.timestamps.dropFirst()).allSatisfy {
            $0.0 < $0.1
        })

        let source = CGImageSourceCreateWithData(output.spriteJPEG as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, output.tileWidth * SpriteSpec.columns)
        XCTAssertEqual(image?.height, output.tileHeight * SpriteSpec.rows)
    }

    func testLowFrameRateSpriteDuplicatesNearestActualFramesTo24Tiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "low-fps.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            video.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(video)
        let output = try await FFmpegSpriteGenerator.generate(url: video, info: info)
        XCTAssertEqual(output.timestamps.count, SpriteSpec.frameCount)
        XCTAssertTrue(zip(output.timestamps, output.timestamps.dropFirst()).allSatisfy {
            $0.0 <= $0.1
        })
        XCTAssertLessThan(Set(output.timestamps).count, SpriteSpec.frameCount)

        let source = CGImageSourceCreateWithData(output.spriteJPEG as CFData, nil)
        guard let sprite = source.flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("精灵图 JPEG 应可解码")
        }
        for index in 0..<SpriteSpec.frameCount {
            let frame = sprite.cropping(to: CGRect(
                x: (index % SpriteSpec.columns) * output.tileWidth,
                y: (index / SpriteSpec.columns) * output.tileHeight,
                width: output.tileWidth,
                height: output.tileHeight
            ))
            XCTAssertFalse(CoverPicker.stats(for: try XCTUnwrap(frame))?.isNearUniform ?? true)
        }
    }

    func testSingleActualFrameStillProduces24MappedTiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "single-frame.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-frames:v", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-f", "matroska", video.path(percentEncoded: false)
        ])

        let info = MediaProbe.Info(duration: 1, width: 160, height: 120)
        let cover = try await FFmpegSpriteGenerator.generateCover(url: video, info: info)
        let output = try await FFmpegSpriteGenerator.generate(url: video, info: info)
        let coverSource = CGImageSourceCreateWithData(cover.coverJPEG as CFData, nil)
        let coverImage = coverSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(coverImage?.width, SpriteSpec.coverSide)
        XCTAssertEqual(coverImage?.height, SpriteSpec.coverSide)
        XCTAssertEqual(cover.coverTime, 0, accuracy: 0.001)
        XCTAssertEqual(output.timestamps.count, SpriteSpec.frameCount)
        XCTAssertEqual(Set(output.timestamps).count, 1)
        XCTAssertEqual(output.timestamps.first ?? -1, 0, accuracy: 0.001)
    }

    func testOneFPSShortVideoStillProducesCover() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "one-fps.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            video.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(video)
        let cover = try await FFmpegSpriteGenerator.generateCover(url: video, info: info)
        let source = CGImageSourceCreateWithData(cover.coverJPEG as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, SpriteSpec.coverSide)
        XCTAssertEqual(image?.height, SpriteSpec.coverSide)
        XCTAssertTrue([0.0, 1.0].contains { abs($0 - cover.coverTime) < 0.001 })
    }

    func testSinglePointCoverChoosesPreviousFrameWhenItIsNearest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "nearest.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            video.path(percentEncoded: false)
        ])

        let cover = try await FFmpegSpriteGenerator.generateCover(url: video, at: 1.8)
        let source = CGImageSourceCreateWithData(cover.coverJPEG as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, SpriteSpec.coverSide)
        XCTAssertEqual(image?.height, SpriteSpec.coverSide)
        XCTAssertEqual(cover.coverTime, 1, accuracy: 0.001)

        let nearerAfter = try await FFmpegSpriteGenerator.generateCover(url: video, at: 0.8)
        XCTAssertEqual(nearerAfter.coverTime, 1, accuracy: 0.001)
    }

    func testManualCoverEntryFallsBackForUnsupportedAVCodec() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "manual-cover.unknown")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-t", "2", "-c:v", "ffv1", "-f", "avi",
            video.path(percentEncoded: false)
        ])

        let cover = try await SpriteGenerator.generateCoverWithFallback(url: video, at: 1.8)
        let source = CGImageSourceCreateWithData(cover.coverJPEG as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(image?.width, SpriteSpec.coverSide)
        XCTAssertEqual(image?.height, SpriteSpec.coverSide)
        XCTAssertEqual(cover.coverTime, 1, accuracy: 0.001)
    }

    func testNonZeroContainerStartTimeUsesRelativeTimeline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "offset.ts")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-t", "45", "-c:v", "libx264", "-g", "250", "-keyint_min", "250",
            "-sc_threshold", "0", "-pix_fmt", "yuv420p",
            "-muxdelay", "0", "-output_ts_offset", "2.4", "-f", "mpegts",
            video.path(percentEncoded: false)
        ])

        let probe = try ProcessRunner.executable(named: "ffprobe")
        let rawStart = try await ProcessRunner.run(
            executable: probe,
            arguments: [
                "-v", "error", "-show_entries", "format=start_time",
                "-of", "default=noprint_wrappers=1:nokey=1", video.path(percentEncoded: false)
            ],
            timeout: 5
        )
        let startText = String(data: rawStart.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Double(startText ?? "") ?? 0, 2.4, accuracy: 0.001)

        let info = try await FFmpegMediaProbe.probe(video)
        let manualStarted = Date()
        let manual = try await FFmpegSpriteGenerator.generateCover(url: video, at: 1.8)
        let manualElapsed = Date().timeIntervalSince(manualStarted)
        let automatic = try await FFmpegSpriteGenerator.generateCover(url: video, info: info)
        let sprite = try await FFmpegSpriteGenerator.generate(url: video, info: info)

        XCTAssertEqual(manual.coverTime, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(manual.framesDecoded, 8)
        XCTAssertLessThan(manualElapsed, 5)
        XCTAssertGreaterThanOrEqual(automatic.coverTime, 0)
        XCTAssertLessThanOrEqual(automatic.coverTime, info.duration)
        XCTAssertEqual(sprite.timestamps.count, SpriteSpec.frameCount)
        XCTAssertGreaterThanOrEqual(sprite.timestamps.min() ?? -1, 0)
        // 取样窗口收到 0.90 并再扣掉 2 秒片尾余量后，最后一个取样点落在 40.5 秒，
        // 命中的真实帧是 41 秒那一张，不再贴着 44 秒的片尾——那里的 seek 会返回
        // 退出码正常但整幅全黑的帧。
        XCTAssertLessThanOrEqual(sprite.timestamps.max() ?? .infinity, info.duration - 2)
        XCTAssertEqual(sprite.timestamps.last ?? -1, 41, accuracy: 0.001)
    }

    func testPartialAVFrameSetIsRejected() {
        let complete = Array<Int?>(repeating: 1, count: SpriteSpec.frameCount)
        var partial = complete
        partial[7] = nil
        XCTAssertTrue(SpriteGenerator.hasCompleteFrames(
            complete, expectedCount: SpriteSpec.frameCount
        ))
        XCTAssertFalse(SpriteGenerator.hasCompleteFrames(
            partial, expectedCount: SpriteSpec.frameCount
        ))
        XCTAssertFalse(SpriteGenerator.hasCompleteFrames(
            Array(complete.dropLast()), expectedCount: SpriteSpec.frameCount
        ))
    }

    func testUnsupportedCodecUsesIntegratedFallbackWithoutExtensionGate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "legacy-video.unknown")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25",
            "-t", "4", "-c:v", "ffv1", "-f", "avi",
            video.path(percentEncoded: false)
        ])

        let values = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let item = MediaItem(
            url: video,
            size: Int64(try XCTUnwrap(values.fileSize)),
            modifiedAt: values.contentModificationDate ?? Date()
        )
        let coverURL = ThumbnailStore.coverURL(digest: item.key.digest)
        let spriteURL = ThumbnailStore.spriteURL(digest: item.key.digest)
        defer {
            try? FileManager.default.removeItem(at: coverURL)
            try? FileManager.default.removeItem(at: spriteURL)
        }
        let index = MediaIndex(fileURL: directory.appending(path: "index.json"))

        let coverOutcome = await IndexingPipeline.processOne(
            item: item, index: index, stage: .cover
        )
        let spriteOutcome = await IndexingPipeline.processOne(
            item: item, index: index, stage: .sprite
        )
        guard case .succeeded = coverOutcome else {
            return XCTFail("完整流水线应通过 ffmpeg 生成封面")
        }
        guard case .succeeded = spriteOutcome else {
            return XCTFail("完整流水线应通过 ffmpeg 生成精灵图")
        }
        let storedRecord = await index.record(for: item.key)
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.width, 160)
        XCTAssertEqual(record.height, 120)
        XCTAssertNotNil(record.coverTime)
        XCTAssertEqual(record.spriteTimestamps.count, SpriteSpec.frameCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spriteURL.path))
    }

    func testRealFailurePersistsAndIsNotRetried() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appending(path: "not-a-video.data")
        try Data("broken".utf8).write(to: invalid)
        let item = MediaItem(url: invalid, size: 6, modifiedAt: Date())
        let index = MediaIndex(fileURL: directory.appending(path: "index.json"))

        let first = await IndexingPipeline.processOne(
            item: item, index: index, stage: .cover
        )
        guard case .failed = first else {
            return XCTFail("坏文件应记录为真实失败")
        }
        let failedRecord = await index.record(for: item.key)
        XCTAssertNotNil(failedRecord?.failure)

        let second = await IndexingPipeline.processOne(
            item: item, index: index, stage: .cover
        )
        guard case .skipped = second else {
            return XCTFail("相同缓存键的真实失败不应重复探测")
        }
    }

    func testCancellationDoesNotPersistFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cancelled.data")
        try Data("unused".utf8).write(to: file)
        let item = MediaItem(url: file, size: 6, modifiedAt: Date())
        let index = MediaIndex(fileURL: directory.appending(path: "index.json"))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await IndexingPipeline.processOne(
                item: item, index: index, stage: .cover
            )
        }
        let outcome = await task.value
        guard case .cancelled = outcome else {
            return XCTFail("取消应作为独立结果返回")
        }
        let cancelledRecord = await index.record(for: item.key)
        XCTAssertNil(cancelledRecord)
    }

    func testProcessCancellationStopsChild() async throws {
        let task = Task {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    "$|=1; while (1) { print \"x\" x 65536; select undef,undef,undef,0.01; }"
                ],
                timeout: 20
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("被取消的进程不应成功")
        } catch is CancellationError {
            // 预期结果
        }
    }

    func testProcessRunnerDrainsLargeStdoutAndStderrWhileRunning() async throws {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "print STDOUT \"o\" x 2000000; print STDERR \"e\" x 1500000;"
            ],
            timeout: 5
        )
        XCTAssertEqual(output.stdout.count, 2_000_000)
        XCTAssertEqual(output.stderr.count, 1_500_000)
    }

    func testTimeoutBoundaryReturnsWithoutWaitingForUnresponsiveOperation() async throws {
        let stopped = LockedFlag()
        let started = Date()
        do {
            let _: Int = try await AsyncTimeoutBoundary.run(
                timeout: 0.05,
                timeoutError: MediaProbe.ProbeError.timedOut,
                onStop: { stopped.set() },
                operation: {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            continuation.resume(returning: 1)
                        }
                    }
                }
            )
            XCTFail("不响应取消的操作应超时")
        } catch MediaProbe.ProbeError.timedOut {
            // 预期结果
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertTrue(stopped.value)
    }

    // MARK: - 顺序回退的闸门

    /// 取样点全落在纯黑画面上，不该退回顺序解码。
    ///
    /// 顺序回退的滤镜链固定会带上第 0 帧。这条素材开头半秒有画面、其余全黑，
    /// 所以一旦误走回退就能捞到那半秒、把整张精灵图「救」出来——正因为如此，
    /// 它能把两种写法区分开：走回退会成功，不走回退按 blankFrame 失败。
    /// 真实素材里这一趟只是白烧几十秒解码，救不了任何东西。
    func testAllBlankSamplePointsDoNotTriggerSequentialFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "black-tail.mp4")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=s=160x120:r=10:d=0.5",
            "-f", "lavfi", "-i", "color=c=black:s=160x120:r=10:d=29.5",
            "-filter_complex", "[0:v][1:v]concat=n=2:v=1[out]",
            "-map", "[out]", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            video.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(video)
        // 24 个取样点在 0.9 秒到 28 秒之间，全部落在黑画面里
        XCTAssertEqual(info.duration, 30, accuracy: 0.1)

        do {
            _ = try await FFmpegSpriteGenerator.generate(url: video, info: info)
            XCTFail("取样点全黑属于画面无效，应直接报 blankFrame，不该靠顺序回退捞第 0 帧")
        } catch FFmpegSpriteGenerator.GenerateError.blankFrame {
            // 预期结果
        }
    }

    /// 一帧都没解出来才是顺序回退要治的病，这一条必须继续走回退。
    ///
    /// 整条 MPEG-TS 只有开头一个关键帧，任何按时间的输入 seek 都落在 GOP 中间，
    /// 一路读到 EOF 也出不了画面（已实测：24 个取样点全部零输出）。
    func testInputSeekDecodingNothingStillFallsBackToSequentialSheet() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "no-index.ts")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=1",
            "-t", "40", "-c:v", "libx264", "-g", "250", "-keyint_min", "250",
            "-sc_threshold", "0", "-pix_fmt", "yuv420p",
            "-muxdelay", "0", "-f", "mpegts",
            video.path(percentEncoded: false)
        ])

        let info = try await FFmpegMediaProbe.probe(video)
        // 顺序回退是这条素材唯一的出路：不走它这里只能抛错
        let output = try await FFmpegSpriteGenerator.generate(url: video, info: info)
        XCTAssertEqual(output.timestamps.count, SpriteSpec.frameCount)
        XCTAssertEqual(output.tileWidth, SpriteSpec.maxTileDimension)
        XCTAssertGreaterThanOrEqual(output.timestamps.min() ?? -1, 0)
        XCTAssertLessThanOrEqual(output.timestamps.max() ?? .infinity, info.duration)
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let executable = try ProcessRunner.executable(named: "ffmpeg")
        _ = try await ProcessRunner.run(
            executable: executable,
            arguments: ["-y", "-nostdin", "-hide_banner", "-loglevel", "error"] + arguments,
            timeout: 20
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ClipFlowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
