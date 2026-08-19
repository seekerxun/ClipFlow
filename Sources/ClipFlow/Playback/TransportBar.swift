import SwiftUI

/// 播放控制条：播放/暂停、进度、音量/静音、倍速、循环。进度条 hover 读精灵图预览。
struct TransportBar: View {
    var controller: PlaybackController

    @Environment(AppEnvironment.self) private var env

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    /// 逐帧模式下拖动进度条时按帧记，不从时间反推，免得四舍五入差一帧。
    @State private var scrubFrame: Int = 0
    @State private var hoverTime: Double?
    @State private var hoverX: CGFloat?
    @State private var sliderWidth: CGFloat = 0
    @State private var spriteCG: CGImage?
    @State private var coverImage: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: playPauseSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 32)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!controller.isLoaded)
            .focusable(false)
            .help(playPauseHelp)

            if controller.isFrameStepMode {
                frameStepButton(symbol: "backward.frame.fill", delta: -1, help: "上一帧（A / ←）")
                frameStepButton(symbol: "forward.frame.fill", delta: 1, help: "下一帧（D / →）")
            }

            positionLabel

            timelineSlider
                .frame(minWidth: 120, maxWidth: .infinity)

            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: muteSymbol)
                    .frame(width: 22, height: 30)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(controller.isMuted ? "取消静音" : "静音")

            Slider(
                value: Binding(
                    get: { controller.volume },
                    set: { value in
                        controller.setVolume(value)
                        if controller.isMuted { controller.setMuted(false) }
                    }
                ),
                in: 0...100
            )
            .frame(width: 72)
            .controlSize(.small)
            .focusable(false)
            .help("音量")

            Picker("倍速", selection: Binding(
                get: { PlaybackController.nearestSpeed(controller.speed) },
                set: { controller.setSpeed($0) }
            )) {
                ForEach(PlaybackController.speedSteps, id: \.self) { speed in
                    Text(PlaybackController.speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 68)
            .controlSize(.small)
            .focusable(false)
            .help("倍速")

            Button {
                env.toggleFrameStepMode()
            } label: {
                Image(systemName: "film")
                    .foregroundStyle(controller.isFrameStepMode ? Color.accentColor : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(controller.isFrameStepMode ? "退出逐帧模式（G）" : "逐帧模式（G）")

            Button {
                controller.cycleLoopMode()
            } label: {
                Image(systemName: controller.loopMode.symbolName)
                    .foregroundStyle(controller.loopMode == .off ? .secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(controller.loopMode.title)

            Button {
                controller.toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("全屏")
        }
        .frame(minHeight: 42)
        .transaction { $0.animation = nil }
    }

    private var timelineSlider: some View {
        sliderCore
        .disabled(!controller.isLoaded || controller.duration <= 0)
        .focusable(false)
        .controlSize(.small)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { sliderWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in
                        sliderWidth = width
                    }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard previewDuration > 0 else {
                    hoverTime = nil
                    hoverX = nil
                    return
                }
                let width = max(sliderWidth, 1)
                let x = min(max(location.x, 0), width)
                hoverX = x
                hoverTime = (x / width) * previewDuration
            case .ended:
                hoverTime = nil
                hoverX = nil
            }
        }
        .overlay {
            abLoopOverlay
        }
        .overlay(alignment: .top) {
            seekPreviewOverlay
        }
        .task(id: previewLoadID) {
            loadPreviewImages()
        }
    }

    /// 逐帧模式且拿得到帧率时，进度条一格就是一帧。
    private var isFrameTimeline: Bool {
        controller.isFrameStepMode && controller.frameCount > 1
    }

    @ViewBuilder
    private var sliderCore: some View {
        if isFrameTimeline {
            Slider(
                value: Binding(
                    get: { Double(displayFrame) },
                    set: { newValue in
                        scrubFrame = Int(newValue.rounded())
                        scrubTime = controller.time(forFrame: scrubFrame)
                        controller.seek(toFrame: scrubFrame)
                    }
                ),
                in: 0...Double(max(controller.frameCount - 1, 1)),
                step: 1,
                onEditingChanged: handleScrubbing
            )
        } else {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : controller.currentTime },
                    set: { newValue in
                        scrubTime = newValue
                        controller.seek(to: newValue)
                    }
                ),
                in: 0...max(controller.duration, 0.01),
                onEditingChanged: handleScrubbing
            )
        }
    }

    private func handleScrubbing(_ editing: Bool) {
        if editing {
            scrubTime = controller.currentTime
            scrubFrame = controller.currentFrame
        }
        isScrubbing = editing
        if !editing {
            if isFrameTimeline {
                controller.seek(toFrame: scrubFrame)
            } else {
                controller.seek(to: scrubTime)
            }
        }
    }

    private func frameStepButton(symbol: String, delta: Int, help: String) -> some View {
        Button {
            controller.stepFrame(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 32)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!controller.isLoaded)
        .focusable(false)
        .help(help)
    }

    /// 播放位置文本。逐帧模式报帧号，时间挪到悬停提示里。
    @ViewBuilder
    private var positionLabel: some View {
        Text(positionText)
            .font(.system(.caption, design: .monospaced, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.82))
            .frame(minWidth: controller.isFrameStepMode ? 104 : 92, alignment: .leading)
            .help(positionHelp)
    }

    private var positionText: String {
        guard controller.isFrameStepMode else {
            return "\(DisplayFormat.duration(displayTime)) / \(DisplayFormat.duration(controller.duration))"
        }
        guard controller.hasFrameInfo else { return "帧 — / —" }
        return "帧 \(displayFrame) / \(controller.frameCount)"
    }

    private var positionHelp: String {
        guard controller.isFrameStepMode else { return "" }
        guard controller.hasFrameInfo else { return "这个文件读不到帧率，只能按时间走" }
        return String(
            format: "%.2fs / %.2fs　%g fps",
            displayTime, controller.duration, controller.frameRate
        )
    }

    private var displayFrame: Int {
        isScrubbing ? scrubFrame : controller.currentFrame
    }

    private var displayTime: Double {
        isScrubbing ? scrubTime : controller.currentTime
    }

    private var playPauseSymbol: String {
        !controller.isLoaded || controller.isPaused ? "play.fill" : "pause.fill"
    }

    private var playPauseHelp: String {
        !controller.isLoaded || controller.isPaused ? "播放" : "暂停"
    }

    private var muteSymbol: String {
        if controller.isMuted || controller.volume <= 0 { return "speaker.slash.fill" }
        if controller.volume < 40 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    private var previewDigest: String? { env.selectedID }

    private var previewRecord: IndexRecord? {
        guard let id = env.selectedID else { return nil }
        return env.records[id]
    }

    private var previewLoadID: String {
        let digest = previewDigest ?? ""
        let sprite = previewRecord?.hasSprite == true
        let cover = previewRecord?.coverTime ?? -1
        let manual = previewRecord?.manualCoverTime ?? -1
        return "\(digest)-\(sprite)-\(cover)-\(manual)"
    }

    private var previewTime: Double? {
        if isScrubbing { return scrubTime }
        return hoverTime
    }

    /// 悬停预览用的时长。播放内核还没报出时长时退回索引里的那份：
    /// 预览读的是磁盘上的精灵图，本来就不依赖播放器是否已经就绪。
    private var previewDuration: Double {
        if controller.duration > 0 { return controller.duration }
        return previewRecord?.duration ?? 0
    }

    private var previewX: CGFloat? {
        if isScrubbing, previewDuration > 0, sliderWidth > 0 {
            return min(max(scrubTime / previewDuration * sliderWidth, 0), sliderWidth)
        }
        return hoverX
    }

    @ViewBuilder
    private var abLoopOverlay: some View {
        GeometryReader { geo in
            let dur = max(controller.duration, 0.01)
            let w = geo.size.width
            let midY = geo.size.height / 2
            ZStack {
                if let a = controller.loopA, let b = controller.loopB, a < b, controller.duration > 0 {
                    let x0 = CGFloat(min(max(a / dur, 0), 1)) * w
                    let x1 = CGFloat(min(max(b / dur, 0), 1)) * w
                    Capsule()
                        .fill(Color.accentColor.opacity(0.38))
                        .frame(width: max(x1 - x0, 2), height: 4)
                        .position(x: (x0 + x1) / 2, y: midY)
                }
                if let a = controller.loopA, controller.duration > 0 {
                    abMarker
                        .position(x: CGFloat(min(max(a / dur, 0), 1)) * w, y: midY)
                }
                if let b = controller.loopB, controller.duration > 0 {
                    abMarker
                        .position(x: CGFloat(min(max(b / dur, 0), 1)) * w, y: midY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var abMarker: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: 10)
    }

    @ViewBuilder
    private var seekPreviewOverlay: some View {
        if let time = previewTime, let x = previewX, let image = previewImage(at: time) {
            SeekPreview(image: image, time: time)
                .fixedSize()
                .frame(width: 0, height: 0, alignment: .bottom)
                .offset(x: previewOffsetX(hoverX: x), y: -6)
                .allowsHitTesting(false)
        }
    }

    private func previewOffsetX(hoverX: CGFloat) -> CGFloat {
        let half = CGFloat(SpriteSpec.maxTileDimension) / 2
        let raw = hoverX - sliderWidth / 2
        guard sliderWidth > CGFloat(SpriteSpec.maxTileDimension) else { return 0 }
        let minDX = half - sliderWidth / 2
        let maxDX = sliderWidth / 2 - half
        return min(max(raw, minDX), maxDX)
    }

    private func previewImage(at time: Double) -> NSImage? {
        if let spriteCG {
            let index = SeekPreview.frameIndex(
                time: time,
                timestamps: previewRecord?.spriteTimestamps ?? [],
                duration: previewDuration
            )
            if let tile = SeekPreview.tile(from: spriteCG, record: previewRecord, index: index) {
                return tile
            }
        }
        return coverImage
    }

    private func loadPreviewImages() {
        guard let digest = previewDigest else {
            spriteCG = nil
            coverImage = nil
            return
        }
        spriteCG = SeekPreview.loadSprite(digest: digest)
        coverImage = SeekPreview.loadCover(digest: digest)
    }
}
