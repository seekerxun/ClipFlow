import AppKit
import Foundation

/// V0 的验收脚本。
///
/// spike 的全部意义是回答「libmpv 这条路走不走得通」，所以把判定写成可自动执行的，
/// 而不是靠人眼看一眼窗口。用 `CLIPFLOW_SELFTEST=1 swift run` 触发。
@MainActor
enum SelfTest {

    private static var results: [(name: String, passed: Bool, detail: String)] = []

    static func run(player: Player, outDir: String) async {
        // 输出重定向到文件/管道时 stdout 是块缓冲的，挂起时会一个字都看不到
        setvbuf(stdout, nil, _IONBF, 0)
        print("\n=== ClipFlow V0 自测开始 ===\n")

        guard await waitUntil(timeout: 8, { player.isAttached }) else {
            return finish(fatal: "render context 未建立：\(player.status)")
        }
        record("render context 建立 (vo=libmpv + OpenGL)", passed: true, detail: player.status)

        guard await waitUntil(timeout: 15, { player.didLoadFile && player.duration > 0 }) else {
            return finish(fatal: "文件加载超时。状态：\(player.status)")
        }
        record(
            "MKV 解析成功",
            passed: true,
            detail: "\(player.mediaInfo)，时长 \(fmt(player.duration))s"
        )

        // ── 播放推进 ────────────────────────────────────────────
        player.setPaused(false)
        await sleep(1.2)
        let tPlaying = player.currentTimeFromMPV() ?? -1
        record(
            "播放推进",
            passed: tPlaying > 0.3,
            detail: "1.2s 后 time-pos = \(fmt(tPlaying))"
        )

        // ── 真的解出画面了 ──────────────────────────────────────
        let playingShot = outDir + "/frame-playing.png"
        try? FileManager.default.removeItem(atPath: playingShot)
        player.screenshot(to: playingShot)
        await sleep(1.0)
        let playingSize = fileSize(playingShot)
        record(
            "解码出真实画面",
            passed: playingSize > 5_000,
            detail: playingSize > 0
                ? "已写出 \(playingShot)（\(playingSize / 1024) KB）"
                : "截图文件未生成"
        )

        // ── 暂停冻结 ────────────────────────────────────────────
        player.setPaused(true)
        await sleep(0.4)
        let tPauseA = player.currentTimeFromMPV() ?? -1
        await sleep(0.9)
        let tPauseB = player.currentTimeFromMPV() ?? -2
        record(
            "暂停冻结",
            passed: abs(tPauseB - tPauseA) < 0.05,
            detail: "0.9s 间隔内 \(fmt(tPauseA)) → \(fmt(tPauseB))"
        )

        // ── 精确 seek ──────────────────────────────────────────
        player.seek(absolute: 5.0)
        await sleep(0.8)
        let tSeek = player.currentTimeFromMPV() ?? -1
        record(
            "精确 seek 到 5.0s (hr-seek)",
            passed: abs(tSeek - 5.0) < 0.4,
            detail: "落点 \(fmt(tSeek))"
        )

        let seekShot = outDir + "/frame-seek-5s.png"
        try? FileManager.default.removeItem(atPath: seekShot)
        player.screenshot(to: seekShot)
        await sleep(1.0)
        record(
            "seek 后能取到该位置的帧",
            passed: fileSize(seekShot) > 5_000,
            detail: "已写出 \(seekShot)（\(fileSize(seekShot) / 1024) KB）"
        )

        // ── 恢复播放 ────────────────────────────────────────────
        player.setPaused(false)
        await sleep(0.9)
        let tResume = player.currentTimeFromMPV() ?? -1
        record(
            "从暂停恢复播放",
            passed: tResume > tSeek + 0.3,
            detail: "\(fmt(tSeek)) → \(fmt(tResume))"
        )

        finish(fatal: nil)
    }

    // MARK: - 工具

    private static func record(_ name: String, passed: Bool, detail: String) {
        results.append((name, passed, detail))
        print("\(passed ? "  PASS" : "  FAIL")  \(name)\n        \(detail)")
    }

    private static func finish(fatal: String?) {
        if let fatal {
            print("\n  FAIL  \(fatal)")
            results.append(("提前中止", false, fatal))
        }
        let failed = results.filter { !$0.passed }
        print("\n=== 结果：\(results.count - failed.count)/\(results.count) 通过 ===")
        if failed.isEmpty {
            print("V0 验收通过：libmpv + --wid + SwiftUI 这条路走得通。\n")
        } else {
            print("未通过项：" + failed.map(\.name).joined(separator: "、") + "\n")
        }
        fflush(stdout)
        exit(failed.isEmpty ? 0 : 1)
    }

    private static func waitUntil(
        timeout: Double,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int
        else { return 0 }
        return size
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
