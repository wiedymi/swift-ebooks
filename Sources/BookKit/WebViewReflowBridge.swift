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

    let pageTurn = ReflowPageTurnRuntime()
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

        #if os(iOS) || os(visionOS) || os(macOS)
        webView = ReaderSelectionWebView(frame: .zero, configuration: config)
        #else
        webView = WKWebView(frame: .zero, configuration: config)
        #endif

        super.init()

        messageHandlerProxy.delegate = self
        controller.add(messageHandlerProxy, contentWorld: .defaultClient, name: Self.handlerName)
        webView.navigationDelegate = self
        #if os(iOS) || os(tvOS) || os(visionOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.isDirectionalLockEnabled = true
        #endif

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

    func turnPage(transition: PageTransition, forward: Bool, operation: @MainActor () async throws -> Void) async throws {
        try await pageTurn.perform(in: webView, transition: transition, forward: forward, operation: operation)
    }

    func cancelPageTurn() { pageTurn.cancel() }

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
          window.BookKitNativeClearSelection?.();
          document.body.style.margin = '0';
          document.body.style.padding = '0';
          document.documentElement.style.setProperty('--bookkit-viewport-width', '\(viewport.width)px');
          document.documentElement.style.setProperty('--bookkit-viewport-height', '\(viewport.height)px');
          window.BookKitNativeScrollTo(0, 0);
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

    public func goToText(_ range: ReaderTextRange) async throws -> Double? {
        try await waitForDocumentReady()
        let value = try await webView.evaluateJavaScript(
            "window.BookKitNativeGoToText(\(Self.jsJSON(range)))", in: nil, contentWorld: .defaultClient
        )
        return (value as? [String: Any])?["progression"] as? Double
    }

    public func capturePosition() async throws -> Position? {
        guard webView.window != nil, webView.bounds.width > 1, webView.bounds.height > 1 else { return nil }
        try await waitForDocumentReady()
        guard let value = try await webView.evaluateJavaScript("window.BookKitNativePosition()", in: nil, contentWorld: .defaultClient) as? [String: Any],
              let progression = value["progression"] as? Double, progression.isFinite else { return nil }
        return Position(spineIndex: 0, progression: progression, fragment: value["anchor"] as? String)
    }

    public func clearSelection() async throws {
        try await evaluateJavaScript("window.BookKitNativeClearSelection()")
    }

    public func goToAnchor(_ id: String) async throws {
        let js = """
        (() => {
          const target = document.getElementById(\(Self.jsString(id)));
          if (target) {
            window.BookKitNativeScrollIntoView(target);
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

    func setPageZoomAllowed(_ allowed: Bool) async throws {
        try await waitForDocumentReady()
        try Task.checkCancellation()
        try await evaluateJavaScript("""
        window.__bookkitAllowsPageZoom = \(allowed);
        window.BookKitNativeApplyPageZoom();
        """)
        try Task.checkCancellation()
        #if os(iOS) || os(visionOS)
        webView.scrollView.pinchGestureRecognizer?.isEnabled = allowed
        if !allowed { webView.scrollView.setZoomScale(1, animated: false) }
        #elseif os(macOS)
        webView.allowsMagnification = allowed
        if !allowed { webView.magnification = 1 }
        #endif
        if !allowed { try await measurePages() }
    }

    public func setPageColumns(_ columns: PageColumns) async throws {
        try await evaluateJavaScript("""
        window.__bookkitPageColumns = \(Self.jsString(columns.rawValue));
        """)
    }

    public func setReadingMode(_ mode: ReadingMode) async throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        // The reader handles paginated swipes. Native panning would also move the page.
        webView.scrollView.isScrollEnabled = mode == .scroll
        #endif
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
        #if os(iOS) || os(visionOS)
        webView.tintColor = theme.usesDarkSelection
            ? UIColor(red: 0.55, green: 0.76, blue: 1, alpha: 1) : .systemBlue
        #endif
        let js = """
        (() => {
          document.documentElement.style.setProperty('--bookkit-bg', \(Self.jsString(theme.backgroundColor)));
          document.documentElement.style.setProperty('--bookkit-fg', \(Self.jsString(theme.textColor)));
          document.documentElement.style.setProperty('--bookkit-link', \(Self.jsString(theme.linkColor)));
          document.documentElement.style.setProperty('--bookkit-selection-bg', \(Self.jsString(theme.selectionBackgroundColor)));
          document.documentElement.style.setProperty('--bookkit-selection-fg', \(Self.jsString(theme.selectionTextColor)));
          let custom = document.getElementById('bookkit-theme-style');
          if (!custom) {
            custom = document.createElement('style');
            custom.id = 'bookkit-theme-style';
            document.head.appendChild(custom);
          }
          custom.textContent = \(Self.jsString(SanitizeContent.css(theme.customCSS, allowsNetwork: allowsNetwork)));
        })();
        """
        try await evaluateJavaScript(js)
    }

    public func setTypography(_ typography: Typography) async throws {
        let js = """
        (() => {
          const root = document.documentElement;
          root.style.setProperty('--bookkit-font-family', \(Self.jsString(typography.cssFontFamilies)));
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

      const pageWidth = () => Math.max(window.innerWidth || 1, 1);
      const lastPageIndex = () => {
        const extent = Math.max(document.documentElement.scrollWidth || 0, document.body?.scrollWidth || 0);
        return Math.max(Math.ceil((extent - 1) / pageWidth()) - 1, 0);
      };
      const pageOffset = x => {
        const page = Math.round((Number.isFinite(x) ? x : 0) / pageWidth());
        return Math.min(Math.max(page, 0), lastPageIndex()) * pageWidth();
      };
      window.BookKitNativeScrollTo = (x, y) => {
        const paged = isPaginated() && !isFixedLayout();
        // The native surface owns animation. Never start an independent browser
        // scroll that a second page command can interrupt between page edges.
        window.scrollTo({ left: paged ? pageOffset(x) : x, top: paged ? 0 : y, behavior: 'instant' });
      };
      window.BookKitNativeAlignPage = () => {
        if (!isPaginated() || isFixedLayout()) return;
        const left = pageOffset(window.scrollX);
        if (Math.abs(window.scrollX - left) > 0.5 || Math.abs(window.scrollY) > 0.5) {
          window.BookKitNativeScrollTo(left, 0);
        }
      };
      window.BookKitNativeScrollIntoView = target => {
        if (isPaginated() && !isFixedLayout()) {
          const width = pageWidth();
          const left = target.getBoundingClientRect().left + window.scrollX;
          window.BookKitNativeScrollTo(Math.max(0, Math.floor(left / width)) * width, 0);
        } else target.scrollIntoView({ behavior: 'instant', block: 'start', inline: 'nearest' });
      };

      window.BookKitNativeApplyPageZoom = () => {
        // Publication viewport tags must not override the host's zoom policy.
        const metas = Array.from(document.querySelectorAll('meta[name="viewport" i]'));
        const viewport = metas.shift() || document.createElement('meta');
        for (const duplicate of metas) duplicate.remove();
        viewport.name = 'viewport';
        const policy = window.__bookkitAllowsPageZoom === false
          ? 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no'
          : 'width=device-width, initial-scale=1';
        if (viewport.content !== policy) viewport.content = policy;
        if (!viewport.parentNode) document.head.appendChild(viewport);
      };

      window.BookKitNativeApplyReadingMode = () => {
        const root = document.documentElement;
        const body = document.body;
        if (!root || !body) return;
        window.BookKitNativeApplyPageZoom();
        root.dataset.bookkitLayout = isFixedLayout() ? 'fixed' : 'reflowable';
        root.style.setProperty('box-sizing', 'border-box', 'important');
        root.style.setProperty('width', '100%', 'important');
        root.style.setProperty('min-width', '0', 'important');
        root.style.setProperty('max-width', '100%', 'important');
        body.style.setProperty('box-sizing', 'border-box', 'important');
        body.style.setProperty('margin', '0', 'important');
        body.style.setProperty('padding', isFixedLayout() ? '0' : '24px', 'important');
        body.style.setProperty('min-width', '0', 'important');
        body.style.setProperty('position', 'static', 'important');
        body.style.transform = 'none';
        if (!isPaginated() || isFixedLayout()) document.getElementById('bookkit-page-end')?.remove();

        if (isFixedLayout()) {
          root.style.setProperty('overflow', 'hidden', 'important');
          body.style.setProperty('overflow', 'hidden', 'important');
          body.style.columnCount = 'auto';
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
          root.style.setProperty('overflow', 'hidden', 'important');
          body.style.setProperty('overflow', 'visible', 'important');
          body.style.columnGap = '48px';
          body.style.columnFill = 'auto';
          const viewport = Math.max(window.innerWidth || 1, 1);
          const fontSize = parseFloat(getComputedStyle(body).fontSize) || 20;
          const minimumColumn = Math.max(280, fontSize * 16);
          const requested = window.__bookkitPageColumns || 'single';
          const columns = requested !== 'single' && viewport >= minimumColumn * 2 + 96 ? 2 : 1;
          body.style.columnCount = String(columns);
          body.style.columnWidth = `${Math.max((viewport - 48 - (columns - 1) * 48) / columns, 1)}px`;
          body.style.height = `${Math.max(window.innerHeight || 1, 1)}px`;
          body.style.width = `${Math.max(window.innerWidth || 1, 1)}px`;
          body.style.maxWidth = 'none';
        } else {
          root.style.setProperty('overflow', 'hidden auto', 'important');
          // Clip overflow at the body so WebKit's native scroll view measures only
          // the viewport width. Unlike hidden, clip does not create another scroll container.
          body.style.setProperty('overflow', 'clip visible', 'important');
          body.style.columnCount = 'auto';
          body.style.columnGap = 'normal';
          body.style.columnFill = 'balance';
          body.style.columnWidth = 'auto';
          body.style.height = 'auto';
          body.style.setProperty('width', '100%', 'important');
          body.style.setProperty('max-width', '100%', 'important');
          window.BookKitNativeScrollTo(0, Math.max(window.scrollY || 0, 0));
        }
      };

      window.BookKitNativeApplyAccessibility = () => {
        const root = document.documentElement;
        if (!root) return;
        const settings = window.__bookkitAccessibility || {};
        root.dataset.bookkitVoiceOver = settings.voiceOver ? 'true' : 'false';
        root.dataset.bookkitReducedMotion = settings.reducedMotion ? 'true' : 'false';
        root.style.setProperty('scroll-behavior', 'auto', 'important');

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
          const vw = Math.max(window.innerWidth || 1, 1);
          const x = Math.max(window.scrollX || 0, scrollingElement ? scrollingElement.scrollLeft || 0 : 0);
          return clamp(Math.round(x / vw) / Math.max(lastPageIndex(), 1));
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

      window.BookKitNativePosition = () => ({ progression: computeProgression(), anchor: visibleAnchor() });
      let lastAnnouncedPercent = -100;
      let lastAnnouncedAnchor = null;
      let lastReportedProgression = -1;
      let lastReportedAnchor = null;
      window.BookKitNativeReportPosition = (force = false, requestedProgression = null) => {
        window.BookKitNativeAlignPage();
        const progression = requestedProgression === null || isPaginated()
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
          const lastPage = Math.max(Math.ceil((width - 1) / viewportWidth) - 1, 0);
          const destination = Math.round(lastPage * clamped) * viewportWidth;
          window.BookKitNativeScrollTo(destination, 0);
        } else {
          const height = Math.max(document.documentElement.scrollHeight || 0, document.body ? document.body.scrollHeight || 0 : 0);
          const viewportHeight = Math.max(window.innerHeight || 1, 1);
          const maxScroll = Math.max(height - viewportHeight, 1);
          window.BookKitNativeScrollTo(0, maxScroll * clamped);
        }
      };

      window.BookKitNativeMeasurePages = () => {
        let pageCount = 1;
        let dimension = 0;
        if (isFixedLayout()) {
          pageCount = 1;
          dimension = Math.max(window.innerHeight || 1, 1);
        } else if (isPaginated()) {
          // Removing the last-page spacer can clamp the browser's scroll offset.
          // Keep the page index across measurement, then restore its full edge.
          const visiblePage = Math.round(window.scrollX / pageWidth());
          document.getElementById('bookkit-page-end')?.remove();
          const w = Math.max(document.documentElement.scrollWidth || 0, document.body ? document.body.scrollWidth || 0 : 0);
          const vw = Math.max(window.innerWidth || 1, 1);
          pageCount = Math.max(1, Math.ceil((w - 1) / vw));
          dimension = pageCount * vw;
          // Keep the last screen aligned even when only its first column contains text.
          const end = document.createElement('div');
          end.id = 'bookkit-page-end';
          end.setAttribute('aria-hidden', 'true');
          Object.assign(end.style, { position: 'absolute', left: `${dimension - 1}px`, top: '0',
            width: '1px', height: '1px', margin: '0', padding: '0', pointerEvents: 'none' });
          document.body.appendChild(end);
          window.BookKitNativeScrollTo(Math.min(Math.max(visiblePage, 0), pageCount - 1) * vw, 0);
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

      \(WebViewReflowBridge.textSupportScript)
      window.BookKitNativeApplyDecorations = decorations => {
        window.BookKitNativeApplyTextDecorations(Array.isArray(decorations) ? decorations : []);
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
        const position = Math.max(lastReportedProgression, 0);
        window.BookKitNativeApplyReadingMode();
        window.BookKitNativeMeasurePages();
        window.BookKitNativeGoToProgression(position);
      });
      const reflowAfterFontsLoad = () => {
        const position = Math.max(lastReportedProgression, 0);
        window.BookKitNativeApplyReadingMode();
        window.BookKitNativeMeasurePages();
        window.BookKitNativeGoToProgression(position);
        window.BookKitNativeReportPosition(true);
      };
      document.fonts?.ready.then(reflowAfterFontsLoad);
      document.fonts?.addEventListener('loadingdone', reflowAfterFontsLoad);

      document.addEventListener('keydown', event => {
        if (event.repeat || !['Enter', ' '].includes(event.key)) return;
        const mark = event.target?.closest?.('[data-bookkit-text-mark][role="button"]');
        if (mark) { event.preventDefault(); mark.click(); }
      });

      document.addEventListener('click', event => {
        if (window.getSelection()?.isCollapsed === false) { event.preventDefault(); return; }
        const decorated = event.target?.closest?.('[data-bookkit-text-mark]');
        const highlights = (decorated?.__bookkitMarks || []).filter(mark => mark.group === 'highlight');
        if (highlights.length) {
          event.preventDefault();
          event.stopPropagation();
          // The most recently applied user mark owns a tap where highlights overlap.
          const decoration = highlights[highlights.length - 1];
          post({ type: 'decorationTapped', id: decoration.id, group: decoration.group });
          return;
        }

        const target = event.target && event.target.closest ? event.target.closest('a') : null;
        if (!target) {
          if (window.getSelection()?.isCollapsed === false) return;
          if (event.target?.closest?.('button, input, textarea, select, [contenteditable="true"]')) return;
          const image = event.target?.closest?.('img[data-bookkit-image], image[data-bookkit-image]');
          post({ type: 'custom', name: 'bookkit.tap', payload: {
            x: event.clientX / Math.max(window.innerWidth, 1),
            imageID: image?.getAttribute('data-bookkit-image') || ''
          } });
          return;
        }
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
