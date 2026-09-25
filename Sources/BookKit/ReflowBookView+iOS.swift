#if os(iOS) || os(tvOS)
import SwiftUI
import WebKit
struct BookWebViewContainer: UIViewRepresentable {
    let bridge: WebViewReflowBridge
    let selectionMenu: @MainActor () -> ReaderSelectionMenu?
    let allowsPageZoom: Bool
    func makeUIView(context: Context) -> PageTurnWebView { PageTurnWebView(bridge: bridge) }
    func updateUIView(_ view: PageTurnWebView, context: Context) {
        #if !os(tvOS)
        (bridge.webView as? ReaderSelectionWebView)?.selectionMenu = selectionMenu
        bridge.webView.scrollView.pinchGestureRecognizer?.isEnabled = allowsPageZoom
        #endif
    }
    static func dismantleUIView(_ view: PageTurnWebView, coordinator: ()) { view.detach() }
}

final class PageTurnWebView: UIView {
    private let bridge: WebViewReflowBridge
    private let pageSurface = PageTurnSurface()

    init(bridge: WebViewReflowBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(bridge.webView)
        addSubview(pageSurface)
        bridge.pageTurn.surface = pageSurface
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bridge.webView.bounds.size != bounds.size { bridge.cancelPageTurn() }
        bridge.webView.frame = bounds
        pageSurface.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { bridge.cancelPageTurn() }
    }

    func detach() {
        #if !os(tvOS)
        (bridge.webView as? ReaderSelectionWebView)?.selectionMenu = nil
        #endif
        if bridge.pageTurn.surface === pageSurface {
            bridge.cancelPageTurn()
            bridge.pageTurn.surface = nil
        }
    }
}
#endif
