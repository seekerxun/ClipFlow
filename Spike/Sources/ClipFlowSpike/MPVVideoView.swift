import AppKit
import CMPV
import OpenGL.GL
import OpenGL.GL3
import SwiftUI

/// libmpv render API 的渲染宿主。
///
/// `--wid` 在 macOS 上不被支持（mpv 手册只列了 X11 / win32 / Android），
/// 实测 mpv 会忽略它并自己开一个不受父窗口裁剪的窗口。
/// 因此走 IINA 的路子：`--vo=libmpv` + `mpv_render_context`，由我们自己持有
/// GL 上下文，mpv 只负责往我们给的 FBO 里画。几何和裁剪就完全归 AppKit 管了。
///
/// OpenGL 在 macOS 上已废弃但仍可用，且是 libmpv render API 在 macOS 上唯一
/// 的硬件路径（render API 只有 OpenGL 和 SW 两种，SW 是 CPU 回读，太慢）。
final class MPVGLView: NSOpenGLView {

    private var renderContext: OpaquePointer?
    private let mpvHandle: OpaquePointer?

    /// render context 建好后回调，此时才能 loadfile。
    var onRenderContextReady: (() -> Void)?

    init(frame: NSRect, mpvHandle: OpaquePointer?) {
        self.mpvHandle = mpvHandle

        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            0,
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else {
            fatalError("拿不到 OpenGL 3.2 Core pixel format")
        }
        super.init(frame: frame, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let renderContext {
            mpv_render_context_free(renderContext)
        }
    }

    // MARK: - render context

    override func prepareOpenGL() {
        super.prepareOpenGL()

        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)

        guard renderContext == nil, let mpvHandle else { return }

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
                guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                else { return nil }
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }

        // 不开 ADVANCED_CONTROL：它要求调用方接管更多渲染时序，
        // 履行不到位反而更容易和 mpv 核心互等。基础模式够用。
        var context: OpaquePointer?
        let status = withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPtr),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&context, mpvHandle, &params)
        }

        guard status >= 0, let context else {
            NSLog("mpv_render_context_create 失败: \(status)")
            return
        }
        renderContext = context

        // mpv 从自己的线程通知有新帧，必须转回主线程再画
        mpv_render_context_set_update_callback(context, { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVGLView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.renderFrame() }
        }, Unmanaged.passUnretained(self).toOpaque())

        onRenderContextReady?()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        renderFrame(force: true)
    }

    override func reshape() {
        super.reshape()
        renderFrame(force: true)
    }

    func renderFrame(force: Bool = false) {
        guard let renderContext, let glContext = openGLContext,
              let cgl = glContext.cglContextObj
        else { return }

        if !force {
            let flags = mpv_render_context_update(renderContext)
            guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        }

        glContext.makeCurrentContext()
        CGLLockContext(cgl)
        defer {
            CGLUnlockContext(cgl)
        }

        var boundFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &boundFBO)

        let scale = window?.backingScaleFactor ?? 2
        var fbo = mpv_opengl_fbo(
            fbo: Int32(boundFBO),
            w: Int32(bounds.width * scale),
            h: Int32(bounds.height * scale),
            internal_format: 0
        )
        var flipY: CInt = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }

        glContext.flushBuffer()
    }
}

struct MPVVideoView: NSViewRepresentable {

    let player: Player

    func makeNSView(context: Context) -> MPVGLView {
        let view = MPVGLView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 540),
            mpvHandle: player.rawHandle
        )
        view.onRenderContextReady = { [weak view] in
            guard view != nil else { return }
            player.renderContextIsReady()
        }
        return view
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {}
}
