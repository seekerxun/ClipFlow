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

    func updateNSView(_ nsView: MPVGLBackend, context: Context) {}
}
