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
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
    }
}
