import XCTest

@testable import BookKit

#if canImport(WebKit)
    import WebKit
#endif

final class ReadingTextTests: XCTestCase {
    func testSearchReturnsAllVisibleMatchesAndStableUnicodeRanges() async throws {
        let book = makeTextBook(
            "<head><title>needle</title></head><p>😀 CAFÉ &amp; cafe <b>needle</b>.</p><p hidden>needle</p><script>needle</script><p>Second needle &copy;.</p>"
        )
        let results = try await book.search("needle")
        XCTAssertEqual(results.count, 2)
        let text = try await book.text(inSection: 0)
        XCTAssertEqual(text, "😀 CAFÉ & cafe needle. Second needle ©.")
        for result in results {
            let range = try XCTUnwrap(result.position.textRange)
            XCTAssertEqual(
                (text as NSString).substring(
                    with: NSRange(location: range.start, length: range.end - range.start)), "needle")
            XCTAssertFalse(result.snippet.contains("<"))
        }
        XCTAssertEqual(SearchIndex(book: book).find("needle"), results)
        let accents = try await book.search("cafe", options: .init(diacriticSensitive: false))
        XCTAssertEqual(accents.count, 2)
        let limited = try await book.search("needle", options: .init(maximumResults: 1))
        XCTAssertEqual(limited.count, 1)
        let empty = try await book.search("needle", options: .init(maximumResults: Int.min))
        XCTAssertTrue(empty.isEmpty)
    }

    func testInlineWordsEntitiesAndSentenceLocations() async throws {
        let book = makeTextBook("<p>Hel<b>lo</b> &nbsp; world. Next sentence!</p>")
        let text = try await book.text(inSection: 0)
        XCTAssertEqual(text, "Hello world. Next sentence!")
        let parts = try await book.readingText(inSection: 0)
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            let range = try XCTUnwrap(part.locator.textRange)
            XCTAssertEqual(
                part.text,
                (text as NSString).substring(
                    with: NSRange(location: range.start, length: range.end - range.start)))
            let restored = try JSONDecoder().decode(Locator.self, from: JSONEncoder().encode(part.locator))
            XCTAssertEqual(restored.position.textRange, range)
        }
    }

    func testSpeechChunksStayBoundedAndKeepUnicodeIntact() async throws {
        let book = makeTextBook("<p>" + String(repeating: "😀 word ", count: 30) + "</p>")
        let chunks = try await book.readingText(inSection: 0, maximumUTF16Length: 15)
        XCTAssertTrue(chunks.allSatisfy { $0.text.utf16.count <= 15 && !$0.text.contains("�") })
        let text = try await book.text(inSection: 0)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        do {
            _ = try await book.readingText(inSection: 0, maximumUTF16Length: Int.min)
            XCTFail("Expected an invalid limit error")
        } catch is BookError {}
    }

    func testOldPositionStillDecodes() throws {
        let old = Data(#"{"spineIndex":0,"progression":0.4}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Position.self, from: old).textRange)
    }
}

#if canImport(WebKit)
    @MainActor
    final class ReflowTextTests: XCTestCase {
        func testPendingTextNavigationSurvivesUntilFirstRender() async throws {
            let reader = try await BookReader(book: makeTextBook("<p>First sentence. Last target.</p>"))
            let result = try await reader.search("Last target")
            try await reader.go(to: result[0].position)
            XCTAssertEqual(reader.locator.textRange, result[0].position.textRange)
            let target = reader.position
            try await reader.renderer.renderChapter(at: 0, viewport: .init(width: 300, height: 400))
            try await reader.go(to: target)
            XCTAssertEqual(reader.locator.textRange, target.textRange)
            await reader.shutdown()
        }

        func testSaveCapturesScrollWithoutWaitingForPositionEvents() async throws {
            let store = InMemoryReaderStateStore()
            let reader = try await BookReader(
                book: makeTextBook(String(repeating: "<p>Paragraph.</p>", count: 200)),
                configuration: .init(stateStore: store))
            let bridge = try XCTUnwrap(reader.reflowBridge)
            bridge.webView.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
            #if os(macOS)
                let window = NSWindow(
                    contentRect: CGRect(x: -10_000, y: 0, width: 300, height: 400), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = bridge.webView
                window.orderFront(nil)
                defer { window.close() }
            #endif
            try await reader.renderer.renderChapter(at: 0, viewport: .init(width: 300, height: 400))
            _ = try await bridge.webView.evaluateJavaScript(
                "window.BookKitNativeGoToProgression(0.65)", in: nil, contentWorld: .defaultClient)
            try await reader.saveState()
            let saved = try await store.loadState(forBookID: reader.book.id)
            XCTAssertEqual(try XCTUnwrap(saved?.position.progression), 0.65, accuracy: 0.005)
            await reader.shutdown()
        }

        func testSearchRangeResolvesAcrossElementsAndRecoversAfterMarkupChanges() async throws {
            let book = makeTextBook("<p>First needle.</p><p>😀 A <b>second needle</b> ends.</p>")
            let results = try await book.search("second needle")
            let range = try XCTUnwrap(results.first?.position.textRange)
            let bridge = WebViewReflowBridge()
            try await bridge.setContent(
                html: book.readingOrder[0].content, css: "", viewport: .init(width: 300, height: 400))
            let resolved = try await resolvedText(range, bridge: bridge)
            XCTAssertEqual(resolved, "second needle")
            try await bridge.setContent(
                html: "<p>New introduction.</p><p>First needle.</p><div>😀 A <i>second</i> needle ends.</div>",
                css: "", viewport: .init(width: 300, height: 400))
            let recovered = try await resolvedText(range, bridge: bridge)
            XCTAssertEqual(recovered, "second needle")
            let moved = try await bridge.goToText(range)
            XCTAssertNotNil(moved)
        }

        func testAmbiguousQuoteDoesNotMarkWrongText() async throws {
            let bridge = WebViewReflowBridge()
            try await bridge.setContent(
                html: "<p>same same</p>", css: "", viewport: .init(width: 300, height: 400))
            let invalid = ReaderTextRange(start: 99, end: 103, quote: "same")
            let moved = try await bridge.goToText(invalid)
            XCTAssertNil(moved)
        }

        func testOverlappingMarksPreserveTextAndPublisherStyles() async throws {
            let book = makeTextBook("<p style='color: red'>One <b>two three</b> four.</p>")
            let bridge = WebViewReflowBridge()
            try await bridge.setContent(
                html: book.readingOrder[0].content, css: "", viewport: .init(width: 300, height: 400))
            let first = try await book.search("One two")
            let second = try await book.search("two three")
            let marks = [
                Decoration(
                    id: "saved", group: .highlight, locator: book.locator(for: first[0].position),
                    style: .default(for: .highlight)),
                Decoration(
                    id: "speech", group: .tts, locator: book.locator(for: second[0].position),
                    style: .default(for: .tts)),
            ]
            try await bridge.setDecorations(marks)
            let overlap = try await bridge.webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('[data-bookkit-text-mark]')).filter(x => x.__bookkitMarks.length === 2).map(x => x.textContent).join('')",
                in: nil, contentWorld: .defaultClient)
            XCTAssertEqual(overlap as? String, "two")
            try await bridge.setDecorations([])
            let text = try await bridge.webView.evaluateJavaScript(
                "document.body.textContent", in: nil, contentWorld: .defaultClient)
            XCTAssertEqual(text as? String, "One two three four.")
            let color = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('p').style.color", in: nil, contentWorld: .defaultClient)
            XCTAssertEqual(color as? String, "red")
        }

        func testSelectionHasChapterOffsetsContextAndClearEvent() async throws {
            let book = makeTextBook("<p>Before.</p><p>😀 One <b>two</b> three.</p>")
            let reader = try await BookReader(book: book)
            let bridge = try XCTUnwrap(reader.reflowBridge)
            try await reader.renderer.renderChapter(at: 0, viewport: .init(width: 300, height: 400))
            let selected = expectation(description: "Selected range")
            let events = reader.events
            let task = Task { @MainActor in
                for await event in events {
                    if case .selectionChanged(let value) = event, value.text == "One two three" {
                        selected.fulfill()
                        return
                    }
                }
            }
            _ = try await bridge.webView.evaluateJavaScript(
                """
                const p = document.querySelectorAll('p')[1];
                const r = document.createRange();
                r.setStart(p.firstChild, 3); r.setEnd(p.lastChild, 6);
                const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
                """, in: nil, contentWorld: .defaultClient)
            await fulfillment(of: [selected], timeout: 3)
            task.cancel()
            let selection = try XCTUnwrap(reader.selection)
            let range = try XCTUnwrap(selection.locator.textRange)
            XCTAssertEqual(range.start, 11)
            XCTAssertEqual(range.quote, "One two three")
            XCTAssertEqual(range.prefix, "Before. 😀 ")
            XCTAssertNotNil(selection.range.bounds)
            let mark = try await reader.highlightSelection()
            XCTAssertEqual(mark.first?.locator.textRange, range)
            let retainedSelection = try await bridge.webView.evaluateJavaScript(
                "window.getSelection().toString()", in: nil, contentWorld: .defaultClient)
            XCTAssertEqual(retainedSelection as? String, "One two three")
            try await reader.clearSelection()
            XCTAssertNil(reader.selection)
            await reader.shutdown()
        }

        func testScrollPositionSavesAtClose() async throws {
            let store = InMemoryReaderStateStore()
            let book = makeTextBook(String(repeating: "<p>Read this paragraph.</p>", count: 500))
            let reader = try await BookReader(book: book, configuration: .init(stateStore: store))
            let bridge = try XCTUnwrap(reader.reflowBridge)
            bridge.webView.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
            try await reader.renderer.renderChapter(at: 0, viewport: .init(width: 300, height: 400))
            let moved = expectation(description: "Scroll position")
            let events = reader.events
            let task = Task { @MainActor in
                for await event in events {
                    if case .locatorChanged(let value) = event, value.sectionProgression > 0.69 {
                        moved.fulfill()
                        return
                    }
                }
            }
            try await bridge.goToProgression(0.7)
            await fulfillment(of: [moved], timeout: 3)
            task.cancel()
            await reader.shutdown()
            let saved = try await store.loadState(forBookID: book.id)
            XCTAssertEqual(try XCTUnwrap(saved?.position.progression), 0.7, accuracy: 0.001)
        }

        func testCustomThemeCSSCanBeReplacedAndRemoved() async throws {
            let bridge = WebViewReflowBridge()
            try await bridge.setContent(
                html: "<p>Text</p>", css: "", viewport: .init(width: 300, height: 400))
            try await bridge.setTheme(Theme(customCSS: "p { text-align: right; }"))
            let right = try await bridge.webView.evaluateJavaScript(
                "getComputedStyle(document.querySelector('p')).textAlign", in: nil,
                contentWorld: .defaultClient)
            XCTAssertEqual(right as? String, "right")
            try await bridge.setTheme(.light)
            let reset = try await bridge.webView.evaluateJavaScript(
                "getComputedStyle(document.querySelector('p')).textAlign", in: nil,
                contentWorld: .defaultClient)
            XCTAssertNotEqual(reset as? String, "right")
        }

        private func resolvedText(_ range: ReaderTextRange, bridge: WebViewReflowBridge) async throws
            -> String?
        {
            let json = String(decoding: try JSONEncoder().encode(range), as: UTF8.self)
            return try await bridge.webView.evaluateJavaScript(
                "window.BookKitNativeResolveText(\(json))?.toString()", in: nil, contentWorld: .defaultClient)
                as? String
        }
    }
#endif

func makeTextBook(_ html: String) -> Book {
    Book(
        id: "text-fixture", format: .html, version: "1", metadata: Metadata(title: "Text", authors: []),
        readingOrder: [Chapter(id: "chapter", href: "chapter.html", title: "Chapter", content: html)],
        assets: [], tableOfContents: [], landmarks: [], pageList: [], rawExtensions: [:], diagnostics: [])
}
