import SwiftUI

/// 把 OpenGL 渲染宿主塞进 SwiftUI。具体后端类型只在这里出现，
/// `PlaybackController` 仍然只看到 `MPVRenderBackend`。
struct MPVVideoView: NSViewRepresentable {

    let controller: PlaybackController

    func makeNSView(context: Context) -> MPVGLBackend {
        let view = MPVGLBackend()
        controller.attachRenderBackend(view)
        return view
    }

    /// 播放器实例可能在视图存活期间被换掉。不在这里补挂，画面就留在旧实例上，
    /// 新实例永远等不到渲染就绪，待播文件会一直卡在队列里。
    /// `attachRenderBackend` 对「已经挂好且就绪」的组合是空操作。
    func updateNSView(_ nsView: MPVGLBackend, context: Context) {
        controller.attachRenderBackend(nsView)
    }
}
