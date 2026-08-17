import Observation

/// 应用级共享对象。第 6 块的界面从这里拿播放控制器，以及后续的索引 / 浏览状态。
@Observable
final class AppEnvironment {
    let playback = PlaybackController()
}
