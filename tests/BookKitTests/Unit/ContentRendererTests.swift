import XCTest
@testable import BookKit

@MainActor
final class ContentRendererTests: XCTestCase {
    func testReflowRendererPagingFlow() async throws {
        let bridge = MockReflowBridge()
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: "C1", content: "Hello world"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))

        bridge.emit(.paginationChanged(pageCount: 4, chapterProgressMap: [0: [0, 0.33, 0.66, 1]]))
        bridge.emit(.positionChanged(spineIndex: 0, progression: 0.25, cfi: nil, anchor: nil))
        try await Task.sleep(nanoseconds: 20_000_000)

        let pageCount = renderer.pageCount()
        XCTAssertEqual(pageCount, 4)

        let pos = await renderer.currentPosition()
        XCTAssertEqual(pos.spineIndex, 0)
    }

    func testPDFRendererModeUsesPageAdapter() async throws {
        let book = Book(
            id: "id",
            format: .pdf,
            version: "1.7",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "p1", href: "pdf://page/1", title: "P1", content: "1"),
                Chapter(id: "p2", href: "pdf://page/2", title: "P2", content: "2"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book)
        try await renderer.renderChapter(at: 1, viewport: Viewport(width: 600, height: 800))

        let pageCount = renderer.pageCount()
        XCTAssertEqual(pageCount, 2)
        let current = await renderer.currentPosition()
        XCTAssertEqual(current.spineIndex, 1)
    }

    func testLinkPolicyBlocksExternalByDefault() async throws {
        let bridge = MockReflowBridge()
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        let action = try await renderer.handleLink(
            URL(string: "https://example.com")!,
            context: LinkContext(currentChapterHref: "c1")
        )

        XCTAssertEqual(action, .block)
    }

    func testHandleSpineLinkNavigatesToTargetChapterAndAnchor() async throws {
        let bridge = MockReflowBridge()
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "OPS/ch1.xhtml", title: "C1", content: "<p>Chapter 1</p>"),
                Chapter(id: "c2", href: "OPS/ch2.xhtml", title: "C2", content: "<p>Chapter 2</p><h2 id=\"note-1\">N</h2>"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))

        let action = try await renderer.handleLink(
            URL(string: "ch2.xhtml#note-1", relativeTo: URL(string: "bookkit://chapter/current")!)!,
            context: LinkContext(currentChapterHref: "OPS/ch1.xhtml")
        )

        XCTAssertEqual(action, .follow)
        XCTAssertTrue(bridge.commands.contains(.goToAnchor("note-1")))
        XCTAssertTrue(bridge.commands.contains { command in
            if case let .setContent(html, _, _) = command {
                return html.contains("Chapter 2")
            }
            return false
        })

        let position = await renderer.currentPosition()
        XCTAssertEqual(position.spineIndex, 1)
    }

    func testBridgePositionEventsStayInRenderedChapter() async throws {
        let bridge = MockReflowBridge()
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: "C1", content: "Chapter 1"),
                Chapter(id: "c2", href: "c2", title: "C2", content: "Chapter 2"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        try await renderer.renderChapter(at: 1, viewport: Viewport(width: 390, height: 844))

        // WebViewReflowBridge reports positions relative to the currently rendered chapter.
        bridge.emit(.positionChanged(spineIndex: 0, progression: 0.25, cfi: nil, anchor: nil))
        try await Task.sleep(nanoseconds: 20_000_000)

        let position = await renderer.currentPosition()
        XCTAssertEqual(position.spineIndex, 1)
        XCTAssertEqual(position.progression, 0.25, accuracy: 0.0001)
    }

    func testRendererEventLoopDoesNotRetainRenderer() async throws {
        let bridge = MockReflowBridge()
        weak var weakRenderer: ContentRenderer?

        do {
            let renderer = try ContentRenderer(
                book: Book(
                    id: "id",
                    format: .epub,
                    version: "1",
                    metadata: Metadata(title: "T", authors: []),
                    readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
                    assets: [],
                    tableOfContents: [],
                    landmarks: [],
                    pageList: [],
                    rawExtensions: [:],
                    diagnostics: []
                ),
                reflowBridge: bridge
            )
            weakRenderer = renderer
            await Task.yield()
        }

        await Task.yield()
        XCTAssertNil(weakRenderer)
    }

    func testRestoreStateAndBookmarksProxy() async throws {
        let bridge = MockReflowBridge()
        let store = InMemoryReaderStateStore()
        let book = Book(
            id: "persistent-book",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: "C1", content: "<p>Hello world</p>"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let seedReader = Reader(book: book, stateStore: store)
        try await seedReader.go(to: Position(spineIndex: 0, progression: 0.6))
        _ = try await seedReader.addBookmark(note: "Saved")

        let renderer = try ContentRenderer(book: book, stateStore: store, reflowBridge: bridge)
        try await renderer.restoreState()

        let position = await renderer.currentPosition()
        XCTAssertEqual(position.spineIndex, 0)
        XCTAssertEqual(position.progression, 0.6, accuracy: 0.0001)

        let bookmarks = await renderer.bookmarks()
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.note, "Saved")
    }

    func testRenderInlinesBookKitAssetURLs() async throws {
        let bridge = MockReflowBridge()
        let imageData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        let book = Book(
            id: "asset-book",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(
                    id: "c1",
                    href: "c1",
                    title: "C1",
                    content: #"<p>Before</p><img src="bookkit://asset/img-cover"><p>After</p>"#
                ),
            ],
            assets: [
                Asset(id: "img-cover", href: "images/cover.png", mediaType: "image/png", data: imageData),
            ],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let renderer = try ContentRenderer(book: book, reflowBridge: bridge)
        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))

        let html = bridge.commands.compactMap { command -> String? in
            if case let .setContent(html, _, _) = command {
                return html
            }
            return nil
        }.first

        XCTAssertNotNil(html)
        XCTAssertTrue(html?.contains("data:image/png;base64,") == true)
        XCTAssertFalse(html?.contains("bookkit://asset/img-cover") == true)
    }
}
