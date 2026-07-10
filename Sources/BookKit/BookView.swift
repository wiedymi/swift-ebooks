import Foundation

#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI
import WebKit

public struct BookView: View {
    private let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    @MainActor
    public init(bridge: WebViewReflowBridge) {
        self.webView = bridge.webView
    }

    public var body: some View {
        _BookWebViewContainer(webView: webView)
    }
}

public typealias PageView = BookView

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
