#if os(macOS)
import SwiftUI
import WebKit
struct BookWebViewContainer: NSViewRepresentable {
    let bridge: WebViewReflowBridge
    let selectionMenu: @MainActor () -> ReaderSelectionMenu?
    let allowsPageZoom: Bool
    func makeNSView(context: Context) -> PageTurnWebView { PageTurnWebView(bridge: bridge) }
    func updateNSView(_ view: PageTurnWebView, context: Context) {
        #if !os(tvOS)
        (bridge.webView as? ReaderSelectionWebView)?.selectionMenu = selectionMenu
        bridge.webView.allowsMagnification = allowsPageZoom
        #endif
    }
    static func dismantleNSView(_ view: PageTurnWebView, coordinator: ()) { view.detach() }
}

final class PageTurnWebView: NSView {
    private let bridge: WebViewReflowBridge
    private let pageSurface = PageTurnSurface()
    override var isFlipped: Bool { true }

    init(bridge: WebViewReflowBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(bridge.webView)
        addSubview(pageSurface)
        bridge.pageTurn.surface = pageSurface
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if bridge.webView.bounds.size != bounds.size { bridge.cancelPageTurn() }
        bridge.webView.frame = bounds
        pageSurface.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
