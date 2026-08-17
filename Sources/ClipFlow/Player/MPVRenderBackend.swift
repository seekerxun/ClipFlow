import Foundation

/// 渲染后端抽象。`PlaybackController` 只依赖这一层，不碰 OpenGL。
///
/// macOS 上 `--wid` 不受支持，画面必须由后端自持 GL 上下文、用
/// `mpv_render_context` 画进我们的 FBO。将来 OpenGL 被移除时，换成别的
/// 实现不会动到播放逻辑。
protocol MPVRenderBackend: AnyObject {

    /// render context 建好后调用。此时才能 `loadfile`。
    var onRenderContextReady: (() -> Void)? { get set }

    /// 把 libmpv 句柄交给后端。须在第一次出帧之前调用。
    func attach(mpvHandle: OpaquePointer)

    /// 释放 render context。必须在销毁 mpv 句柄之前调用。
    func detach()
}
