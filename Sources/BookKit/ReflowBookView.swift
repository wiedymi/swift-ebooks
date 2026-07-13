import Foundation

#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI
import WebKit

/// Internal SwiftUI container for the session-owned reflow web view.
struct ReflowBookView: View {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
    }

    @MainActor
    init(bridge: WebViewReflowBridge) {
        self.webView = bridge.webView
    }

    var body: some View {
        _BookWebViewContainer(webView: webView)
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
private struct _BookWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}
#elseif os(macOS)
private struct _BookWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> WKWebView { webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}
#endif

#endif
