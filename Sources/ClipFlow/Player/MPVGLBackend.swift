import AppKit
import OpenGL.GL
import OpenGL.GL3

/// OpenGL 渲染后端：`vo=libmpv` + `mpv_render_context` + 自持 GL 上下文。
///
/// `--wid` 在 macOS 上不被支持（mpv 手册只列了 X11 / win32 / Android），
/// 实测 mpv 会忽略它并自己开一个不受父窗口裁剪的窗口。因此走 IINA 的路子：
/// 由我们持有 GL 上下文，mpv 只往我们给的 FBO 里画。几何和裁剪归 AppKit。
///
/// 不开 `MPV_RENDER_PARAM_ADVANCED_CONTROL`：它要求调用方接管更多渲染时序，
/// 履行不到位反而更容易和 mpv 核心互等。
final class MPVGLBackend: NSOpenGLView, MPVRenderBackend {

    var onRenderContextReady: (() -> Void)?

    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var updateCoalescer: RenderUpdateCoalescer?
    private var updateCallbackContext: UnsafeMutableRawPointer?
    private var didNotifyReady = false
    private var activeInteractions: Set<Interaction> = []
    private var windowObservers: [NSObjectProtocol] = []

    private enum Interaction: Hashable {
        case liveResize
        case fullscreenTransition
    }

    init() {
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
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360), pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
    }

    /// 键盘归窗口收键视图，画面不抢焦点。
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        detach()
    }

    // MARK: - MPVRenderBackend

    func attach(mpvHandle: OpaquePointer) {
        self.mpvHandle = mpvHandle
        tryCreateRenderContext()
    }

    func detach() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        activeInteractions.removeAll()
        updateCoalescer?.invalidate()
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let updateCallbackContext {
            Unmanaged<RenderUpdateCoalescer>.fromOpaque(updateCallbackContext).release()
            self.updateCallbackContext = nil
        }
        updateCoalescer = nil
        mpvHandle = nil
        didNotifyReady = false
        onRenderContextReady = nil
    }

    // MARK: - render context

    override func prepareOpenGL() {
        super.prepareOpenGL()

        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)

        tryCreateRenderContext()
    }

    private func tryCreateRenderContext() {
        guard renderContext == nil, let mpvHandle, openGLContext != nil else { return }

        openGLContext?.makeCurrentContext()

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

        let coalescer = RenderUpdateCoalescer { [weak self] force in
            self?.renderLatestFrame(force: force)
        }
        coalescer.setInteractive(!activeInteractions.isEmpty)
        updateCoalescer = coalescer
        // C 回调只接触独立合并器，不跨线程解引用 NSView。显式 retain 到 render
        // context 释放之后，避免关闭窗口时尾随回调访问已经销毁的视图。
        let callbackContext = Unmanaged.passRetained(coalescer).toOpaque()
        updateCallbackContext = callbackContext
        mpv_render_context_set_update_callback(context, { ctx in
            guard let ctx else { return }
            let coalescer = Unmanaged<RenderUpdateCoalescer>.fromOpaque(ctx).takeUnretainedValue()
            coalescer.request()
        }, callbackContext)

        guard !didNotifyReady else { return }
        didNotifyReady = true
        onRenderContextReady?()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        updateCoalescer?.request(force: true)
    }

    override func reshape() {
        super.reshape()
        updateCoalescer?.request(force: true)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        setInteraction(.liveResize, active: true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setInteraction(.liveResize, active: false)
        updateCoalescer?.request(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFullscreenTransition(in: window)
    }

    private func renderLatestFrame(force: Bool) {
        guard let renderContext, let glContext = openGLContext,
              let cgl = glContext.cglContextObj
        else { return }

        // 即使因尺寸变化而强制重画也消费 update 标志，避免同一更新随后再画一次。
        let flags = mpv_render_context_update(renderContext)
        guard force || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }

        glContext.makeCurrentContext()
        CGLLockContext(cgl)
        defer { CGLUnlockContext(cgl) }

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

    private func observeFullscreenTransition(in window: NSWindow?) {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        activeInteractions.remove(.fullscreenTransition)
        updateCoalescer?.setInteractive(!activeInteractions.isEmpty)
        guard let window else { return }

        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                self?.setInteraction(.fullscreenTransition, active: true)
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                self.setInteraction(.fullscreenTransition, active: false)
                self.updateCoalescer?.request(force: true)
            })
        }
    }

    private func setInteraction(_ interaction: Interaction, active: Bool) {
        if active {
            activeInteractions.insert(interaction)
        } else {
            activeInteractions.remove(interaction)
        }
        updateCoalescer?.setInteractive(!activeInteractions.isEmpty)
    }
}
