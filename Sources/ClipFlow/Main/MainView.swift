import SwiftUI

/// 主界面。左侧素材浏览区 + 右侧播放区，界面部分尚未搭建。
///
/// 当前阶段先把扫描 / 索引 / 预览图这条流水线跑通并量出性能数据，
/// 用 `CLIPFLOW_BENCH=<目录> ClipFlow.app/Contents/MacOS/ClipFlow` 验证。
struct MainView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("ClipFlow")
                .font(.largeTitle.weight(.semibold))
            Text("索引流水线已就位，界面搭建中")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
