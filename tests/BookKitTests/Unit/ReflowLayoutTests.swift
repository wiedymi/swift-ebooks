import XCTest
@testable import BookKit

@MainActor
final class ReflowLayoutTests: XCTestCase {
    func testRenderSendsExpectedBridgeCommands() async throws {
        let bridge = MockReflowBridge()
        let layout = ReflowLayout(bridge: bridge)

        let chapter = Chapter(id: "c1", href: "c1", title: "C1", content: "<p>Hello</p>")
        try await layout.render(
            chapter: chapter,
            baseCSS: "p { color: red; }",
            viewport: Viewport(width: 400, height: 700),
            theme: .light,
            typography: .default
        )

        XCTAssertTrue(bridge.commands.contains { command in
            if case .setContent = command { return true }
            return false
        })
        XCTAssertTrue(bridge.commands.contains(.measurePages))
        XCTAssertTrue(bridge.commands.contains(.setPublicationLayout(.reflowable)))
    }

    func testFixedChapterUsesScaledPageWrapper() async throws {
        let bridge = MockReflowBridge()
        let layout = ReflowLayout(bridge: bridge)
        let chapter = Chapter(
            id: "fixed",
            href: "fixed.xhtml",
            title: "Fixed",
            content: "<div class=\"page\">Artwork</div>",
            mediaType: "application/xhtml+xml",
            page: PagePresentation(pixelWidth: 1200, pixelHeight: 1800)
        )

        try await layout.render(
            chapter: chapter,
            viewport: Viewport(width: 600, height: 900)
        )

        XCTAssertTrue(bridge.commands.contains(.setPublicationLayout(.fixed)))
        guard let command = bridge.commands.first(where: {
            if case .setContent = $0 { return true }
            return false
        }), case let .setContent(html, css, _) = command else {
            return XCTFail("Expected setContent")
        }
        XCTAssertTrue(html.contains("id=\"bookkit-fixed-page\""))
        XCTAssertTrue(html.contains("data-width=\"1200\""))
        XCTAssertTrue(html.contains("data-height=\"1800\""))
        XCTAssertTrue(css.contains("transform-origin"))
    }

    func testAppliesIncomingEventsToState() async throws {
        let bridge = MockReflowBridge()
        let layout = ReflowLayout(bridge: bridge)

        bridge.emit(.paginationChanged(pageCount: 12, chapterProgressMap: [0: [0.0, 0.5, 1.0]]))
        bridge.emit(.positionChanged(spineIndex: 0, progression: 0.5, cfi: nil, anchor: "mid"))
        bridge.emit(.contentHeightChanged(999))

        try await Task.sleep(nanoseconds: 20_000_000)

        let map = layout.pageMap()
        XCTAssertEqual(map.pageCount, 12)

        let position = layout.position()
        XCTAssertEqual(position?.spineIndex, 0)
        XCTAssertEqual(position?.progression, 0.5)
        XCTAssertEqual(position?.fragment, "mid")

        let height = layout.contentHeight()
        XCTAssertEqual(height, 999)
    }

    func testPageMapIsAssociatedWithRenderedSpineIndex() async throws {
        let bridge = MockReflowBridge()
        let layout = ReflowLayout(bridge: bridge)
        let chapter = Chapter(id: "c3", href: "c3", title: "C3", content: "Chapter 3")

        try await layout.render(
            chapter: chapter,
            spineIndex: 2,
            viewport: Viewport(width: 400, height: 700)
        )
        bridge.emit(.paginationChanged(pageCount: 3, chapterProgressMap: [0: [0, 0.5, 1]]))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(layout.pageMap().chapterProgressMap[2], [0, 0.5, 1])
        XCTAssertNil(layout.pageMap().chapterProgressMap[0])
    }

    func testEventLoopDoesNotRetainLayout() async {
        let bridge = MockReflowBridge()
        weak var weakLayout: ReflowLayout?

        do {
            let layout = ReflowLayout(bridge: bridge)
            weakLayout = layout
            await Task.yield()
        }

        await Task.yield()
        XCTAssertNil(weakLayout)
    }
}
