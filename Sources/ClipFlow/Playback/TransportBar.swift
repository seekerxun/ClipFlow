import SwiftUI

/// 播放控制条：播放/暂停、进度、音量/静音、倍速、循环。不做进度条预览。
struct TransportBar: View {
    var controller: PlaybackController

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : controller.currentTime },
                    set: { newValue in
                        scrubTime = newValue
                        controller.seek(to: newValue)
                    }
                ),
                in: 0...max(controller.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = controller.currentTime
                    }
                    isScrubbing = editing
                    if !editing {
                        controller.seek(to: scrubTime)
                    }
                }
            )
            .disabled(!controller.isLoaded || controller.duration <= 0)
            .focusable(false)
            .controlSize(.small)

            HStack(spacing: 10) {
                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .disabled(!controller.isLoaded)
                .focusable(false)
                .help(controller.isPaused ? "播放" : "暂停")

                Text("\(DisplayFormat.duration(displayTime)) / \(DisplayFormat.duration(controller.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 88, alignment: .leading)

                Spacer(minLength: 8)

                Button {
                    controller.toggleMute()
                } label: {
                    Image(systemName: muteSymbol)
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
                .focusable(false)
                .help("倍速")

                Button {
                    controller.cycleLoopMode()
                } label: {
                    Image(systemName: controller.loopMode.symbolName)
                        .foregroundStyle(controller.loopMode == .off ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(controller.loopMode.title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .transaction { $0.animation = nil }
    }

    private var displayTime: Double {
        isScrubbing ? scrubTime : controller.currentTime
    }

    private var muteSymbol: String {
        if controller.isMuted || controller.volume <= 0 { return "speaker.slash.fill" }
        if controller.volume < 40 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }
}
