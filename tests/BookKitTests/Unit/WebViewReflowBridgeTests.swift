#if canImport(WebKit)
import XCTest
@testable import BookKit

@MainActor
final class WebViewReflowBridgeTests: XCTestCase {
    func testOfflineBlocksEncodedResourcesAndCanBeEnabledAgain() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(png)
        let server = try LocalHTTPServer(response: response)
        let url = try await server.start()
        defer { server.stop() }
        let bridge = WebViewReflowBridge()
        let encoded = url.absoluteString.replacingOccurrences(of: "http:", with: "http&#58;")
        let html = "<img src='\(encoded)?a'><img srcset='\(encoded)?b 1x'>"
        for (allowed, expectedRequests) in [(false, 0), (true, 2), (false, 2)] {
            if expectedRequests > 0 { try await bridge.setNetworkAccessAllowed(allowed) }
            try await bridge.setContent(html: html, css: "", viewport: Viewport(width: 320, height: 480))
            let width = try await bridge.webView.callAsyncJavaScript(
                """
                return await Promise.all([...document.images].map(img => new Promise((resolve, reject) => {
                  const timer = setTimeout(() => reject(new Error('Image did not finish')), 4000);
                  const finish = () => { clearTimeout(timer); resolve(img.naturalWidth); };
                  if (img.complete) finish();
                  else { img.onload = finish; img.onerror = finish; }
                })));
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient
            )
            XCTAssertEqual(width as? [Int], allowed ? [1, 1] : [0, 0])
            XCTAssertEqual(server.requests.count, expectedRequests)
        }
        XCTAssertEqual(server.requests.count, 2)
    }

    func testBootstrapCanPostReadyEventToNativeHandler() async throws {
        let bridge = WebViewReflowBridge()
        let events = bridge.events
        try await Task.sleep(nanoseconds: 100_000_000)

        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 390, height: 844)
        )

        let event = await firstReadyEvent(from: events)
        XCTAssertEqual(event, .ready)
    }

    func testEventsAreBroadcastToEverySubscriber() async throws {
        let bridge = WebViewReflowBridge()
        let firstReady = expectation(description: "First subscriber receives ready")
        let secondReady = expectation(description: "Second subscriber receives ready")
        let firstEvents = bridge.events
        let secondEvents = bridge.events
        let firstTask = Task { @MainActor in
            for await event in firstEvents where event == .ready {
                firstReady.fulfill()
                return
            }
        }
        let secondTask = Task { @MainActor in
            for await event in secondEvents where event == .ready {
                secondReady.fulfill()
                return
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 320, height: 240)
        )

        await fulfillment(of: [firstReady, secondReady], timeout: 1)
        firstTask.cancel()
        secondTask.cancel()
    }

    func testBridgeRuntimeIsIsolatedFromPageWorld() async throws {
        let bridge = WebViewReflowBridge()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 390, height: 844)
        )

        let value = try await bridge.webView.evaluateJavaScript(
            "typeof window.BookKitNativeMeasurePages"
        )
        XCTAssertEqual(value as? String, "undefined")
    }

    func testCustomPluginCanReceiveCommandAndPostTypedEvent() async throws {
        let plugin = ReflowScriptPlugin(
            identifier: "example.echo",
            source: """
            window.BookKit.registerCommand('example.echo', payload => {
              window.BookKit.post('example.echoed', payload);
              return payload;
            });
            """
        )
        let bridge = WebViewReflowBridge(
            configuration: WebViewReflowConfiguration(plugins: [plugin])
        )
        let eventReceived = expectation(description: "Custom plugin event")
        let events = bridge.events
        let eventTask = Task { @MainActor in
            for await event in events {
                if event == .custom(
                    name: "example.echoed",
                    payload: .object(["message": .string("hello")])
                ) {
                    eventReceived.fulfill()
                    return
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 390, height: 844)
        )
        let result = try await bridge.callPlugin(
            "example.echo",
            payload: .object(["message": .string("hello")])
        )

        XCTAssertEqual(result, .object(["message": .string("hello")]))
        await fulfillment(of: [eventReceived], timeout: 1)
        eventTask.cancel()
    }

    func testCustomPluginReceivesContentLifecycleHook() async throws {
        let plugin = ReflowScriptPlugin(
            identifier: "example.lifecycle",
            source: """
            window.BookKit.on('contentDidChange', context => {
              window.BookKit.post('example.contentReady', context);
            });
            """
        )
        let bridge = WebViewReflowBridge(
            configuration: WebViewReflowConfiguration(plugins: [plugin])
        )
        let received = expectation(description: "Content lifecycle event")
        let events = bridge.events
        let task = Task { @MainActor in
            for await event in events {
                guard case let .custom(name, payload) = event,
                      name == "example.contentReady",
                      case let .object(context) = payload,
                      context["viewport"] != nil
                else {
                    continue
                }
                received.fulfill()
                return
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await bridge.setContent(
            html: "<p>Hello</p>",
            css: "",
            viewport: Viewport(width: 320, height: 240)
        )

        await fulfillment(of: [received], timeout: 1)
        task.cancel()
    }

    func testAccessibilitySettingsReachRenderedDocument() async throws {
        let bridge = WebViewReflowBridge()
        try await bridge.setContent(
            html: "<main><h1>Accessible chapter</h1></main>",
            css: "",
            viewport: Viewport(width: 390, height: 844)
        )

        try await bridge.setAccessibility(
            ReaderAccessibilitySettings(
                isVoiceOverEnabled: true,
                forceScrollWhenVoiceOverEnabled: true,
                prefersReducedMotion: true,
                announcesPositionChanges: true
            )
        )

        let value = try await bridge.webView.evaluateJavaScript(
            "({ voiceOver: document.documentElement.dataset.bookkitVoiceOver, "
                + "reducedMotion: document.documentElement.dataset.bookkitReducedMotion })"
        ) as? [String: String]
        XCTAssertEqual(value?["voiceOver"], "true")
        XCTAssertEqual(value?["reducedMotion"], "true")
    }

    func testProgressionCommandPublishesLivePosition() async throws {
        let bridge = WebViewReflowBridge()
        bridge.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let received = expectation(description: "Progression position received")
        let events = bridge.events
        let eventTask = Task { @MainActor in
            for await event in events {
                if case let .positionChanged(_, progression, _, _) = event,
                   progression > 0.6
                {
                    received.fulfill()
                    return
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await bridge.setContent(
            html: String(repeating: "<p>A line of rendered publication text.</p>", count: 120),
            css: "p { margin: 12px 0; font-size: 18px; line-height: 1.5; }",
            viewport: Viewport(width: 320, height: 240)
        )
        try await bridge.goToProgression(0.75)

        await fulfillment(of: [received], timeout: 2)
        eventTask.cancel()
    }

    func testRenderedPublicationLinkNavigatesThroughNativeRenderer() async throws {
        let bridge = WebViewReflowBridge()
        bridge.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let book = Book(
            id: "web-link-test",
            format: .epub,
            version: "3.0",
            metadata: Metadata(title: "Links", authors: []),
            readingOrder: [
                Chapter(
                    id: "one",
                    href: "OPS/one.xhtml",
                    title: "One",
                    content: #"<a id="next" href="two.xhtml#target">Next chapter</a>"#
                ),
                Chapter(
                    id: "two",
                    href: "OPS/two.xhtml",
                    title: "Two",
                    content: #"<h1 id="target">Destination</h1>"#
                ),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        let navigated = expectation(description: "Native renderer followed publication link")
        let events = renderer.events
        let eventTask = Task { @MainActor in
            for await event in events {
                if case let .locatorChanged(locator) = event,
                   locator.sectionIndex == 1,
                   locator.anchor == "target"
                {
                    navigated.fulfill()
                    return
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await renderer.renderChapter(
            at: 0,
            viewport: Viewport(width: 320, height: 240)
        )
        _ = try await bridge.webView.evaluateJavaScript("document.getElementById('next').click()")

        await fulfillment(of: [navigated], timeout: 2)
        eventTask.cancel()
        let position = await renderer.currentPosition()
        XCTAssertEqual(position.spineIndex, 1)
        XCTAssertEqual(position.fragment, "target")
    }

    private func firstReadyEvent(from events: AsyncStream<ReflowBridgeEvent>) async -> ReflowBridgeEvent? {
        await withTaskGroup(of: ReflowBridgeEvent?.self) { group in
            group.addTask {
                for await event in events {
                    if event == .ready {
                        return event
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
#endif
