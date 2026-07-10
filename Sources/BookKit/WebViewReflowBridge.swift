import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
public final class WebViewReflowBridge: NSObject, ReflowBridge, WKScriptMessageHandler {
    private static let handlerName = "bookkitBridge"

    public let webView: WKWebView
    public let events: AsyncStream<ReflowBridgeEvent>

    private let continuation: AsyncStream<ReflowBridgeEvent>.Continuation
    private let messageHandlerProxy: WeakScriptMessageHandler

    public override init() {
        var streamContinuation: AsyncStream<ReflowBridgeEvent>.Continuation!
        events = AsyncStream<ReflowBridgeEvent> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
        messageHandlerProxy = WeakScriptMessageHandler()

        let config = WKWebViewConfiguration()
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePreferences

        let controller = WKUserContentController()
        let script = WKUserScript(source: Self.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(script)
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        messageHandlerProxy.delegate = self
        controller.add(messageHandlerProxy, name: Self.handlerName)

        webView.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>", baseURL: nil)
    }

    deinit {
        continuation.finish()
    }

    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else {
            return
        }

        guard let event = BridgeMessageValidator.decode(body: message.body) else {
            return
        }

        continuation.yield(event)
    }

    public func setContent(html: String, css: String, viewport: Viewport) async throws {
        let safeHTML = SanitizeContent.run(html)
        let js = """
        (() => {
          const html = \(Self.jsString(safeHTML));
          const css = \(Self.jsString(css));
          if (!document.head) {
            const head = document.createElement('head');
            document.documentElement.appendChild(head);
          }
          if (!document.body) {
            const body = document.createElement('body');
            document.documentElement.appendChild(body);
          }

          let style = document.getElementById('bookkit-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'bookkit-style';
            document.head.appendChild(style);
          }

          style.textContent = css;
          document.body.innerHTML = html;
          document.body.style.margin = '0';
          document.body.style.padding = '0';
          document.documentElement.style.width = '\(viewport.width)px';
          document.documentElement.style.height = '\(viewport.height)px';
          window.scrollTo(0, 0);
          if (window.BookKitNativeApplyReadingMode) window.BookKitNativeApplyReadingMode();
          if (window.BookKitNativeApplyDecorations) window.BookKitNativeApplyDecorations(window.__bookkitDecorations || []);

          if (window.BookKitNativeEmitReady) window.BookKitNativeEmitReady();
          if (window.BookKitNativeMeasurePages) window.BookKitNativeMeasurePages();
        })();
        """

        try await evaluateJavaScript(js)
    }

    public func goToAnchor(_ id: String) async throws {
        let js = """
        (() => {
          const target = document.getElementById(\(Self.jsString(id)));
          if (target) {
            target.scrollIntoView();
          }
          if (window.BookKitNativeReportPosition) window.BookKitNativeReportPosition();
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func goToProgression(_ value: Double) async throws {
        let clamped = min(max(value, 0), 1)
        let js = """
        (() => {
          if (window.BookKitNativeGoToProgression) {
            window.BookKitNativeGoToProgression(\(clamped));
          }
          if (window.BookKitNativeReportPosition) window.BookKitNativeReportPosition();
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setReadingMode(_ mode: ReadingMode) async throws {
        let js = """
        (() => {
          if (window.BookKitNativeSetReadingMode) {
            window.BookKitNativeSetReadingMode(\(Self.jsString(mode.rawValue)));
          }
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setTheme(_ theme: Theme) async throws {
        let js = """
        (() => {
          document.documentElement.style.setProperty('--bookkit-bg', \(Self.jsString(theme.backgroundColor)));
          document.documentElement.style.setProperty('--bookkit-fg', \(Self.jsString(theme.textColor)));
          document.documentElement.style.setProperty('--bookkit-link', \(Self.jsString(theme.linkColor)));
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setTypography(_ typography: Typography) async throws {
        let js = """
        (() => {
          const root = document.documentElement;
          root.style.setProperty('--bookkit-font-family', \(Self.jsString(typography.fontFamily)));
          root.style.setProperty('--bookkit-font-size', \(Self.jsString("\(typography.fontSize)px")));
          root.style.setProperty('--bookkit-line-height', \(Self.jsString(String(typography.lineHeight))));
          root.style.setProperty('--bookkit-letter-spacing', \(Self.jsString("\(typography.letterSpacing)px")));
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setDecorations(_ decorations: [Decoration]) async throws {
        let js = """
        (() => {
          const payload = \(Self.jsJSON(decorations));
          window.__bookkitDecorations = Array.isArray(payload) ? payload : [];
          if (window.BookKitNativeApplyDecorations) {
            window.BookKitNativeApplyDecorations(window.__bookkitDecorations);
          }
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func measurePages() async throws {
        try await evaluateJavaScript("window.BookKitNativeMeasurePages && window.BookKitNativeMeasurePages();")
    }

    private func evaluateJavaScript(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func jsString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let json = String(data: data, encoding: .utf8),
           json.count >= 4
        {
            // ["..."] -> "..."
            let start = json.index(after: json.startIndex)
            let end = json.index(before: json.endIndex)
            return String(json[start..<end])
        }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func jsJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return json
    }

    private static let bootstrapScript = """
    (() => {
      if (window.__bookkitBridgeInstalled) return;
      window.__bookkitBridgeInstalled = true;
      window.__bookkitReadingMode = 'scroll';
      window.__bookkitDecorations = [];

      const post = payload => {
        try {
          window.webkit.messageHandlers.bookkitBridge.postMessage(payload);
        } catch (_) {
          // Ignore posting errors for non-hosted contexts.
        }
      };

      const isPaginated = () => window.__bookkitReadingMode === 'paginated';
      const clamp = value => Math.max(0, Math.min(1, value));

      window.BookKitNativeApplyReadingMode = () => {
        const root = document.documentElement;
        const body = document.body;
        if (!root || !body) return;

        if (isPaginated()) {
          root.style.overflow = 'hidden';
          root.style.overflowX = 'auto';
          root.style.overflowY = 'hidden';
          body.style.overflow = 'hidden';
          body.style.columnGap = '0px';
          body.style.columnFill = 'auto';
          body.style.columnWidth = `${Math.max(window.innerWidth || 1, 1)}px`;
          body.style.height = `${Math.max(window.innerHeight || 1, 1)}px`;
          body.style.width = 'auto';
          body.style.maxWidth = 'none';
        } else {
          root.style.overflow = 'auto';
          root.style.overflowX = 'hidden';
          root.style.overflowY = 'auto';
          body.style.overflow = 'visible';
          body.style.columnGap = 'normal';
          body.style.columnFill = 'balance';
          body.style.columnWidth = 'auto';
          body.style.height = 'auto';
          body.style.width = '100%';
          body.style.maxWidth = '100%';
        }
      };

      const computeProgression = () => {
        if (isPaginated()) {
          const w = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const vw = Math.max(window.innerWidth || 1, 1);
          return clamp((window.scrollX || 0) / Math.max(w - vw, 1));
        }
        const h = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
        const vh = Math.max(window.innerHeight || 1, 1);
        return clamp((window.scrollY || 0) / Math.max(h - vh, 1));
      };

      window.BookKitNativeEmitReady = () => {
        post({ type: 'ready' });
      };

      window.BookKitNativeSetReadingMode = mode => {
        window.__bookkitReadingMode = mode === 'paginated' ? 'paginated' : 'scroll';
        window.BookKitNativeApplyReadingMode();
        window.BookKitNativeMeasurePages();
      };

      window.BookKitNativeReportPosition = () => {
        post({
          type: 'positionChanged',
          spineIndex: 0,
          progression: computeProgression()
        });
      };

      window.BookKitNativeGoToProgression = progression => {
        const clamped = clamp(Number(progression || 0));
        if (isPaginated()) {
          const width = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const viewportWidth = Math.max(window.innerWidth || 1, 1);
          const maxScroll = Math.max(width - viewportWidth, 1);
          window.scrollTo(maxScroll * clamped, 0);
        } else {
          const height = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
          const viewportHeight = Math.max(window.innerHeight || 1, 1);
          const maxScroll = Math.max(height - viewportHeight, 1);
          window.scrollTo(0, maxScroll * clamped);
        }
      };

      window.BookKitNativeMeasurePages = () => {
        let pageCount = 1;
        let dimension = 0;
        if (isPaginated()) {
          const w = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const vw = Math.max(window.innerWidth || 1, 1);
          pageCount = Math.max(1, Math.ceil(w / vw));
          dimension = w;
        } else {
          const h = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
          const vh = Math.max(window.innerHeight || 1, 1);
          pageCount = Math.max(1, Math.ceil(h / vh));
          dimension = h;
        }
        const progress = [];
        for (let i = 0; i < pageCount; i++) {
          progress.push(pageCount === 1 ? 0 : i / (pageCount - 1));
        }
        post({
          type: 'paginationChanged',
          pageCount,
          chapterProgressMap: { '0': progress }
        });
        post({ type: 'contentHeightChanged', value: dimension });
        window.BookKitNativeReportPosition();
      };

      const clearDecorations = () => {
        document.querySelectorAll('[data-bookkit-decoration-id]').forEach(element => {
          element.removeAttribute('data-bookkit-decoration-id');
          element.removeAttribute('data-bookkit-decoration-group');
          element.style.removeProperty('background-color');
          element.style.removeProperty('color');
          element.style.removeProperty('text-decoration');
          element.style.removeProperty('text-decoration-color');
          element.style.removeProperty('cursor');
        });
      };

      window.BookKitNativeApplyDecorations = decorations => {
        clearDecorations();
        const list = Array.isArray(decorations) ? decorations : [];
        for (const decoration of list) {
          if (!decoration || !decoration.id) continue;
          const locator = decoration.locator || {};
          const anchor = locator.anchor;
          if (!anchor) continue;
          const target = document.getElementById(anchor);
          if (!target) continue;

          target.setAttribute('data-bookkit-decoration-id', String(decoration.id));
          target.setAttribute('data-bookkit-decoration-group', String(decoration.group || 'highlight'));

          const style = decoration.style || {};
          if (style.backgroundColor) target.style.setProperty('background-color', style.backgroundColor);
          if (style.textColor) target.style.setProperty('color', style.textColor);
          if (style.underlineColor) {
            target.style.setProperty('text-decoration', 'underline');
            target.style.setProperty('text-decoration-color', style.underlineColor);
          }
          target.style.setProperty('cursor', 'pointer');
        }
      };

      document.addEventListener('scroll', () => {
        window.BookKitNativeReportPosition();
      }, { passive: true });

      window.addEventListener('resize', () => {
        window.BookKitNativeApplyReadingMode();
        window.BookKitNativeMeasurePages();
      });

      document.addEventListener('selectionchange', () => {
        const selection = window.getSelection ? window.getSelection() : null;
        if (!selection || selection.rangeCount === 0) return;
        const text = (selection.toString() || '').trim();
        if (!text) return;
        const range = selection.getRangeAt(0);
        post({
          type: 'selectionChanged',
          start: range.startOffset || 0,
          end: range.endOffset || 0,
          text
        });
      });

      document.addEventListener('click', event => {
        const decorated = event.target && event.target.closest ? event.target.closest('[data-bookkit-decoration-id]') : null;
        if (decorated) {
          post({
            type: 'decorationTapped',
            id: decorated.getAttribute('data-bookkit-decoration-id') || '',
            group: decorated.getAttribute('data-bookkit-decoration-group') || 'highlight'
          });
        }

        const target = event.target && event.target.closest ? event.target.closest('a') : null;
        if (!target) return;
        const href = target.getAttribute('href') || '';

        let kind = 'unsupported';
        if (href.startsWith('#')) kind = 'anchor';
        else if (/^https?:/i.test(href)) kind = 'external';
        else if (/^javascript:/i.test(href)) kind = 'unsupported';
        else if (href.length > 0) kind = 'spine';

        post({ type: 'linkTapped', url: href, kind });

        if (kind === 'external' || kind === 'unsupported') {
          event.preventDefault();
        }
      });
    })();
    """
}

@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WebViewReflowBridge?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
#endif
