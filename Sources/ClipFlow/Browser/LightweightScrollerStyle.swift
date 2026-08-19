import AppKit
import SwiftUI

/// 把 SwiftUI 的素材滚动区收敛为 macOS 覆盖式细滚动条。
///
/// 探针放在滚动内容内部，因此能拿到 SwiftUI 背后的 `NSScrollView`；只调整
/// 系统滚动条的呈现，不接管滚动手势、位置或列表选中态。
struct LightweightScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerProbeView {
        ScrollerProbeView()
    }

    func updateNSView(_ nsView: ScrollerProbeView, context: Context) {
        nsView.scheduleUpdate()
    }
}

final class ScrollerProbeView: NSView {
    private var hasScheduledUpdate = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !hasScheduledUpdate else { return }
        hasScheduledUpdate = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hasScheduledUpdate = false
            applyStyle()
        }
    }

    private func applyStyle() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light

        if scrollView.hasVerticalScroller,
           !(scrollView.verticalScroller is FixedWidthScroller) {
            scrollView.verticalScroller = FixedWidthScroller()
        }

        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
    }
}

/// 系统覆盖式滚动条会在鼠标悬停时把滑块横向撑满。这里保留原生拖动、
/// 页跳转和滚动位置同步，只把绘制固定为 5pt，避免压住列表的蓝色选中框。
private final class FixedWidthScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        var knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }

        let width: CGFloat = 5
        let trailingInset: CGFloat = 2
        knobRect.origin.x = bounds.maxX - trailingInset - width
        knobRect.size.width = width
        knobRect = knobRect.insetBy(dx: 0, dy: min(2, knobRect.height / 4))

        NSColor.white.withAlphaComponent(0.38).setFill()
        NSBezierPath(
            roundedRect: knobRect,
            xRadius: width / 2,
            yRadius: width / 2
        ).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 覆盖式滚动条不画轨道，只保留上面的细滑块。
    }
}
