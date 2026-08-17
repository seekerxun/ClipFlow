import SwiftUI

/// 播放画面区域。控制条在 `TransportBar`，快捷键在根视图。
struct PlayerView: View {
    let controller: PlaybackController

    var body: some View {
        MPVVideoView(controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}
