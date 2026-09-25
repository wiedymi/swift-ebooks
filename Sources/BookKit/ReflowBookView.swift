import Foundation

#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI
import WebKit

/// Internal SwiftUI container for the session-owned web view and page overlay.
struct ReflowBookView: View {
    let bridge: WebViewReflowBridge
    let selectionMenu: @MainActor () -> ReaderSelectionMenu?
    let allowsPageZoom: Bool
    var body: some View { BookWebViewContainer(bridge: bridge, selectionMenu: selectionMenu, allowsPageZoom: allowsPageZoom) }
}

#if os(visionOS)
struct BookWebViewContainer: UIViewRepresentable {
    let bridge: WebViewReflowBridge
    let selectionMenu: @MainActor () -> ReaderSelectionMenu?
    let allowsPageZoom: Bool
    func makeUIView(context: Context) -> WKWebView { bridge.webView }
    func updateUIView(_ view: WKWebView, context: Context) {
        (view as? ReaderSelectionWebView)?.selectionMenu = selectionMenu
        view.scrollView.pinchGestureRecognizer?.isEnabled = allowsPageZoom
    }
}
#endif
#endif
