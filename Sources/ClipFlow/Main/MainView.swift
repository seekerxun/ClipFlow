import SwiftUI

/// 主界面。第 6 块会做成左侧素材浏览 + 右侧播放；本块先把画面嵌进来，无素材时空白。
struct MainView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        PlayerView(controller: env.playback)
    }
}
