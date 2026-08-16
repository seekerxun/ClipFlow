import AppKit
import SwiftUI

/// mpv 用 `--wid` 挂载的宿主 view。
///
/// 这里刻意保持成一个空壳：mpv 会在它内部自己建 layer 来画。
/// 我们唯一要做的是保证它有稳定的地址和生命周期。
final class MPVContainerView: NSView, NSViewLike {

    var rawPointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// mpv 挂载前先铺一层黑底，避免看到窗口默认背景。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 只在第一次真正进入窗口层级时回调一次。
    /// mpv 需要一个已经挂到 window 上的 view 才能正确建立渲染上下文。
    var onAttachedToWindow: (() -> Void)?
    private var didAttach = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAttach else { return }
        didAttach = true
        onAttachedToWindow?()
    }
}

struct MPVVideoView: NSViewRepresentable {

    let player: Player

    func makeNSView(context: Context) -> MPVContainerView {
        let view = MPVContainerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.onAttachedToWindow = { [weak view] in
            guard let view else { return }
            player.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: MPVContainerView, context: Context) {}
}
