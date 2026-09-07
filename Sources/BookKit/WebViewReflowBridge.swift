import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
struct WebViewReflowConfiguration {
    public var plugins: [ReflowScriptPlugin]
    public var customizeWebViewConfiguration: (@MainActor (WKWebViewConfiguration) -> Void)?

    public init(
        plugins: [ReflowScriptPlugin] = [],
        customizeWebViewConfiguration: (@MainActor (WKWebViewConfiguration) -> Void)? = nil
    ) {
        self.plugins = plugins
        self.customizeWebViewConfiguration = customizeWebViewConfiguration
    }
}

@MainActor
final class WebViewReflowBridge: NSObject, ReflowBridge, WKScriptMessageHandler, WKNavigationDelegate {
    private static let handlerName = "bookkitBridge"

    public let webView: WKWebView
    public var events: AsyncStream<ReflowBridgeEvent> {
        eventHub.stream()
    }

    private let eventHub = EventHub<ReflowBridgeEvent>()
    private let messageHandlerProxy: WeakScriptMessageHandler
    private var allowsNetwork = false
    private var networkBlockRules: WKContentRuleList?
    private var isDocumentReady = false
    private var documentLoadError: Error?
    private var documentReadyWaiters: [CheckedContinuation<Void, Error>] = []
    private var documentNavigation: WKNavigation?

    public init(configuration bridgeConfiguration: WebViewReflowConfiguration = .init()) {
        messageHandlerProxy = WeakScriptMessageHandler()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePreferences
        bridgeConfiguration.customizeWebViewConfiguration?(config)

        let controller = config.userContentController
        let script = WKUserScript(
            source: Self.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        )
        controller.addUserScript(script)
        for plugin in bridgeConfiguration.plugins {
            controller.addUserScript(
                WKUserScript(
                    source: plugin.source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: .defaultClient
                )
            )
        }

        webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        messageHandlerProxy.delegate = self
        controller.add(messageHandlerProxy, contentWorld: .defaultClient, name: Self.handlerName)
        webView.navigationDelegate = self

        documentNavigation = webView.loadHTMLString(
            "<!doctype html><html><head><meta charset='utf-8'>"
                + "<meta name='viewport' content='width=device-width, initial-scale=1'>"
                + "</head><body></body></html>",
            baseURL: nil
        )
    }

    public func webView(_: WKWebView, didFinish navigation: WKNavigation?) {
        guard navigation === documentNavigation else {
            return
        }
        isDocumentReady = true
        documentLoadError = nil
        documentNavigation = nil
        let waiters = documentReadyWaiters
        documentReadyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func webView(
        _: WKWebView,
        didFail _: WKNavigation?,
        withError error: Error
    ) {
        failDocumentLoad(error)
    }

    public func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation?,
        withError error: Error
    ) {
        failDocumentLoad(error)
    }

    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else {
            return
        }

        guard let event = BridgeMessageValidator.decode(body: message.body) else {
            return
        }

        eventHub.yield(event)
    }

    public func setContent(html: String, css: String, viewport: Viewport) async throws {
        try await applyNetworkPolicy()
        let safeHTML = SanitizeContent.run(html, allowsNetwork: allowsNetwork)
        let safeCSS = SanitizeContent.css(css, allowsNetwork: allowsNetwork)
        let js = """
        (() => {
          const html = \(Self.jsString(safeHTML));
          const css = \(Self.jsString(safeCSS));
          const context = { viewport: { width: \(viewport.width), height: \(viewport.height) } };
          if (window.BookKitNativeEmitHook) window.BookKitNativeEmitHook('contentWillChange', context);
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
          document.documentElement.style.setProperty('--bookkit-viewport-width', '\(viewport.width)px');
          document.documentElement.style.setProperty('--bookkit-viewport-height', '\(viewport.height)px');
          window.scrollTo(0, 0);
          if (window.BookKitNativeApplyReadingMode) window.BookKitNativeApplyReadingMode();
          if (window.BookKitNativeApplyAccessibility) window.BookKitNativeApplyAccessibility();
          if (window.BookKitNativeApplyDecorations) window.BookKitNativeApplyDecorations(window.__bookkitDecorations || []);
          if (window.BookKitNativeEmitHook) window.BookKitNativeEmitHook('contentDidChange', context);

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
          if (window.BookKitNativeReportPosition) window.BookKitNativeReportPosition(true);
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
          if (window.BookKitNativeReportPosition) {
            window.BookKitNativeReportPosition(true, \(clamped));
          }
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

    public func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws {
        let js = """
        (() => {
          window.__bookkitAccessibility = {
            voiceOver: \(settings.isVoiceOverEnabled),
            reducedMotion: \(settings.prefersReducedMotion),
            announcesPositionChanges: \(settings.announcesPositionChanges)
          };
          if (window.BookKitNativeApplyAccessibility) {
            window.BookKitNativeApplyAccessibility();
          }
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setPublicationLayout(_ layout: PublicationLayout) async throws {
        let js = """
        (() => {
          window.__bookkitPublicationLayout = \(Self.jsString(layout.rawValue));
          if (window.BookKitNativeApplyReadingMode) window.BookKitNativeApplyReadingMode();
          if (window.BookKitNativeMeasurePages) window.BookKitNativeMeasurePages();
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setNetworkAccessAllowed(_ allowed: Bool) async throws {
        allowsNetwork = allowed
        try await applyNetworkPolicy()
    }

    private func applyNetworkPolicy() async throws {
        if networkBlockRules == nil {
            networkBlockRules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "BookKitOffline-v1",
                encodedContentRuleList: """
                [
                  {"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
                  {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
                  {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}
                ]
                """
            )
        }
        guard let networkBlockRules else {
            throw BookError.renderingFailed("Unable to enforce offline resource policy")
        }
        let controller = webView.configuration.userContentController
        controller.remove(networkBlockRules)
        if !allowsNetwork { controller.add(networkBlockRules) }
    }

    public func callPlugin(_ name: String, payload: BridgeValue = .null) async throws -> BridgeValue {
        try await waitForDocumentReady()
        let result = try await webView.callAsyncJavaScript(
            "return await window.BookKitNativeDispatch(command, payload);",
            arguments: [
                "command": name,
                "payload": payload.foundationValue,
            ],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let result else {
            return .null
        }
        return BridgeValue(foundationValue: result) ?? .null
    }

    public func measurePages() async throws {
        try await evaluateJavaScript("window.BookKitNativeMeasurePages && window.BookKitNativeMeasurePages();")
    }

    private func evaluateJavaScript(_ script: String) async throws {
        try await waitForDocumentReady()
        _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    }

    private func waitForDocumentReady() async throws {
        if isDocumentReady {
            return
        }
        if let documentLoadError {
            throw BookError.renderingFailed(documentLoadError.localizedDescription)
        }
        try await withCheckedThrowingContinuation { continuation in
            documentReadyWaiters.append(continuation)
        }
    }

    private func failDocumentLoad(_ error: Error) {
        documentLoadError = error
        documentNavigation = nil
        let waiters = documentReadyWaiters
        documentReadyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: BookError.renderingFailed(error.localizedDescription))
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
      window.__bookkitAccessibility = {
        voiceOver: false,
        reducedMotion: false,
        announcesPositionChanges: false
      };

      const post = payload => {
        try {
          window.webkit.messageHandlers.bookkitBridge.postMessage(payload);
        } catch (_) {
          // Ignore posting errors for non-hosted contexts.
        }
      };

      const commandHandlers = new Map();
      const lifecycleHandlers = new Map();
      const normalizeName = name => String(name || '').trim();
      window.BookKit = Object.freeze({
        post(name, payload = null) {
          const normalized = normalizeName(name);
          if (!normalized) throw new TypeError('BookKit event names cannot be empty');
          post({ type: 'custom', name: normalized, payload });
        },
        registerCommand(name, handler) {
          const normalized = normalizeName(name);
          if (!normalized) throw new TypeError('BookKit command names cannot be empty');
          if (typeof handler !== 'function') throw new TypeError('BookKit command handlers must be functions');
          if (commandHandlers.has(normalized)) throw new Error(`BookKit command already registered: ${normalized}`);
          commandHandlers.set(normalized, handler);
        },
        on(name, handler) {
          const normalized = normalizeName(name);
          if (!normalized) throw new TypeError('BookKit hook names cannot be empty');
          if (typeof handler !== 'function') throw new TypeError('BookKit hook handlers must be functions');
          const handlers = lifecycleHandlers.get(normalized) || new Set();
          handlers.add(handler);
          lifecycleHandlers.set(normalized, handlers);
          return () => handlers.delete(handler);
        }
      });
      window.BookKitNativeDispatch = async (name, payload) => {
        const normalized = normalizeName(name);
        const handler = commandHandlers.get(normalized);
        if (!handler) throw new Error(`Unknown BookKit command: ${normalized}`);
        return await handler(payload);
      };
      window.BookKitNativeEmitHook = (name, payload) => {
        const handlers = lifecycleHandlers.get(name);
        if (!handlers) return;
        for (const handler of handlers) {
          try {
            handler(payload);
          } catch (error) {
            post({
              type: 'custom',
              name: 'bookkit.pluginError',
              payload: { hook: name, message: String(error && error.message ? error.message : error) }
            });
          }
        }
      };

      const isPaginated = () => window.__bookkitReadingMode === 'paginated';
      const isFixedLayout = () => window.__bookkitPublicationLayout === 'fixed';
      const clamp = value => Math.max(0, Math.min(1, value));

      window.BookKitNativeApplyReadingMode = () => {
        const root = document.documentElement;
        const body = document.body;
        if (!root || !body) return;

        if (isFixedLayout()) {
          root.style.overflow = 'hidden';
          root.style.overflowX = 'hidden';
          root.style.overflowY = 'hidden';
          body.style.overflow = 'hidden';
          body.style.columnGap = 'normal';
          body.style.columnFill = 'balance';
          body.style.columnWidth = 'auto';
          body.style.width = `${Math.max(window.innerWidth || 1, 1)}px`;
          body.style.height = `${Math.max(window.innerHeight || 1, 1)}px`;
          body.style.maxWidth = 'none';
          const page = document.getElementById('bookkit-fixed-page');
          if (page) {
            const declaredWidth = Math.max(Number(page.dataset.width) || window.innerWidth || 1, 1);
            const declaredHeight = Math.max(Number(page.dataset.height) || window.innerHeight || 1, 1);
            const scale = Math.min(
              Math.max(window.innerWidth || 1, 1) / declaredWidth,
              Math.max(window.innerHeight || 1, 1) / declaredHeight
            );
            page.style.position = 'absolute';
            page.style.width = `${declaredWidth}px`;
            page.style.height = `${declaredHeight}px`;
            page.style.transform = `scale(${scale})`;
            page.style.left = `${Math.max(((window.innerWidth || declaredWidth) - declaredWidth * scale) / 2, 0)}px`;
            page.style.top = `${Math.max(((window.innerHeight || declaredHeight) - declaredHeight * scale) / 2, 0)}px`;
          }
        } else if (isPaginated()) {
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

      window.BookKitNativeApplyAccessibility = () => {
        const root = document.documentElement;
        if (!root) return;
        const settings = window.__bookkitAccessibility || {};
        root.dataset.bookkitVoiceOver = settings.voiceOver ? 'true' : 'false';
        root.dataset.bookkitReducedMotion = settings.reducedMotion ? 'true' : 'false';
        root.style.scrollBehavior = settings.reducedMotion ? 'auto' : 'smooth';

        let liveRegion = document.getElementById('bookkit-position-announcer');
        if (settings.announcesPositionChanges) {
          if (!liveRegion) {
            liveRegion = document.createElement('div');
            liveRegion.id = 'bookkit-position-announcer';
            liveRegion.setAttribute('role', 'status');
            liveRegion.setAttribute('aria-live', 'polite');
            liveRegion.setAttribute('aria-atomic', 'true');
            Object.assign(liveRegion.style, {
              position: 'fixed', width: '1px', height: '1px', overflow: 'hidden',
              clipPath: 'inset(50%)', whiteSpace: 'nowrap'
            });
            document.body && document.body.appendChild(liveRegion);
          }
        } else if (liveRegion) {
          liveRegion.remove();
        }
      };

      const computeProgression = () => {
        if (isFixedLayout()) return 0;
        const scrollingElement = document.scrollingElement || document.documentElement;
        if (isPaginated()) {
          const w = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const vw = Math.max(window.innerWidth || 1, 1);
          const x = Math.max(window.scrollX || 0, scrollingElement ? scrollingElement.scrollLeft || 0 : 0);
          return clamp(x / Math.max(w - vw, 1));
        }
        const h = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
        const vh = Math.max(window.innerHeight || 1, 1);
        const y = Math.max(window.scrollY || 0, scrollingElement ? scrollingElement.scrollTop || 0 : 0);
        return clamp(y / Math.max(h - vh, 1));
      };

      window.BookKitNativeEmitReady = () => {
        post({ type: 'ready' });
      };

      window.BookKitNativeSetReadingMode = mode => {
        window.__bookkitReadingMode = mode === 'paginated' ? 'paginated' : 'scroll';
        window.BookKitNativeApplyReadingMode();
        window.BookKitNativeMeasurePages();
      };

      const visibleAnchor = () => {
        if (!document.elementsFromPoint) return null;
        const x = Math.max(1, Math.min((window.innerWidth || 2) / 2, (window.innerWidth || 2) - 1));
        const y = Math.max(1, Math.min(24, (window.innerHeight || 2) - 1));
        for (const element of document.elementsFromPoint(x, y)) {
          const anchored = element && element.closest ? element.closest('[id]') : null;
          if (anchored && anchored.id && anchored.id !== 'bookkit-position-announcer') return anchored.id;
        }
        return null;
      };

      let lastAnnouncedPercent = -100;
      let lastAnnouncedAnchor = null;
      let lastReportedProgression = -1;
      let lastReportedAnchor = null;
      window.BookKitNativeReportPosition = (force = false, requestedProgression = null) => {
        const progression = requestedProgression === null
          ? computeProgression()
          : clamp(Number(requestedProgression));
        const anchor = visibleAnchor();
        if (!force
          && Math.abs(progression - lastReportedProgression) < 0.0001
          && anchor === lastReportedAnchor) {
          return;
        }
        lastReportedProgression = progression;
        lastReportedAnchor = anchor;
        post({
          type: 'positionChanged',
          spineIndex: 0,
          progression,
          anchor
        });
        window.BookKitNativeEmitHook('positionChanged', { progression, anchor });

        const settings = window.__bookkitAccessibility || {};
        const percent = Math.round(progression * 100);
        const shouldAnnounce = anchor !== lastAnnouncedAnchor || Math.abs(percent - lastAnnouncedPercent) >= 5;
        if (settings.announcesPositionChanges && shouldAnnounce) {
          const liveRegion = document.getElementById('bookkit-position-announcer');
          if (liveRegion) liveRegion.textContent = `Reading position ${percent} percent`;
          lastAnnouncedPercent = percent;
          lastAnnouncedAnchor = anchor;
        }
      };

      window.BookKitNativeGoToProgression = progression => {
        if (isFixedLayout()) return;
        const clamped = clamp(Number(progression || 0));
        const scrollingElement = document.scrollingElement || document.documentElement;
        if (isPaginated()) {
          const width = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const viewportWidth = Math.max(window.innerWidth || 1, 1);
          const maxScroll = Math.max(width - viewportWidth, 1);
          window.scrollTo(maxScroll * clamped, 0);
          if (scrollingElement) scrollingElement.scrollLeft = maxScroll * clamped;
        } else {
          const height = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
          const viewportHeight = Math.max(window.innerHeight || 1, 1);
          const maxScroll = Math.max(height - viewportHeight, 1);
          window.scrollTo(0, maxScroll * clamped);
          if (scrollingElement) scrollingElement.scrollTop = maxScroll * clamped;
        }
      };

      window.BookKitNativeMeasurePages = () => {
        let pageCount = 1;
        let dimension = 0;
        if (isFixedLayout()) {
          pageCount = 1;
          dimension = Math.max(window.innerHeight || 1, 1);
        } else if (isPaginated()) {
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

      let positionAnimationFrame = 0;
      const reportScrolledPosition = () => {
        if (positionAnimationFrame) return;
        positionAnimationFrame = window.requestAnimationFrame(() => {
          positionAnimationFrame = 0;
          window.BookKitNativeReportPosition();
        });
      };
      window.addEventListener('scroll', reportScrolledPosition, { passive: true });
      document.addEventListener('scroll', reportScrolledPosition, { passive: true, capture: true });

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
        window.BookKitNativeEmitHook('selectionChanged', {
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
        event.preventDefault();
        const href = target.getAttribute('href') || '';

        let kind = 'unsupported';
        if (href.startsWith('#')) kind = 'anchor';
        else if (/^https?:/i.test(href)) kind = 'external';
        else if (/^javascript:/i.test(href)) kind = 'unsupported';
        else if (href.length > 0) kind = 'spine';

        post({ type: 'linkTapped', url: href, kind });
        window.BookKitNativeEmitHook('linkTapped', { url: href, kind });

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
