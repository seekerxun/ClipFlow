import SwiftUI

/// 播放画面区域。先把 libmpv 的画面嵌进 SwiftUI；控制条和快捷键留给第 6 块。
struct PlayerView: View {
    let controller: PlaybackController

    var body: some View {
        MPVVideoView(controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}
