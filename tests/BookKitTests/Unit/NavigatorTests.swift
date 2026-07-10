import XCTest
@testable import BookKit

@MainActor
final class NavigatorTests: XCTestCase {
    func testLocatorExposesSectionProgressAndAnchor() async throws {
        let bridge = MockReflowBridge()
        let renderer = try ContentRenderer(
            book: makeBook(),
            reflowBridge: bridge
        )

        try await renderer.renderChapter(at: 1, viewport: Viewport(width: 390, height: 844))
        bridge.emit(.positionChanged(spineIndex: 1, progression: 0.25, cfi: "epubcfi(/6/2)", anchor: "note-1"))
        try await Task.sleep(nanoseconds: 20_000_000)

        let locator = await renderer.currentLocator()
        XCTAssertEqual(locator.sectionIndex, 1)
        XCTAssertEqual(locator.sectionHref, "OPS/ch2.xhtml")
        XCTAssertEqual(locator.sectionProgression, 0.25, accuracy: 0.0001)
        XCTAssertEqual(locator.totalProgression, 0.625, accuracy: 0.0001)
        XCTAssertEqual(locator.anchor, "note-1")
        XCTAssertEqual(locator.cfi, "epubcfi(/6/2)")
    }

    func testJumpHistorySupportsBackAndForward() async throws {
        let bridge = MockReflowBridge()
        let renderer = try ContentRenderer(
            book: makeBook(),
            reflowBridge: bridge
        )

        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))

        let target = Locator(
            sectionIndex: 1,
            sectionHref: "OPS/ch2.xhtml",
            sectionProgression: 0.3,
            totalProgression: 0.65,
            anchor: nil,
            cfi: nil,
            textContext: nil
        )
        try await renderer.go(to: target)

        XCTAssertTrue(renderer.canGoBack())
        XCTAssertFalse(renderer.canGoForward())

        let back = try await renderer.goBack()
        XCTAssertEqual(back?.sectionIndex, 0)
        XCTAssertFalse(renderer.canGoBack())
        XCTAssertTrue(renderer.canGoForward())

        let forward = try await renderer.goForward()
        XCTAssertEqual(forward?.sectionIndex, 1)
        XCTAssertEqual(try XCTUnwrap(forward?.sectionProgression), 0.3, accuracy: 0.0001)
    }

    func testPreferencesPersistModeThemeAndTypography() async throws {
        let store = InMemoryReaderStateStore()
        let bridge = MockReflowBridge()
        let renderer = try ContentRenderer(
            book: makeBook(),
            stateStore: store,
            reflowBridge: bridge
        )

        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))
        try await renderer.setReadingMode(.paginated)
        try await renderer.setTheme(.dark)
        try await renderer.setTypography(Typography(fontFamily: "Georgia", fontSize: 20, lineHeight: 1.8, letterSpacing: 0.2))

        let renderer2 = try ContentRenderer(
            book: makeBook(),
            stateStore: store,
            reflowBridge: MockReflowBridge()
        )
        try await renderer2.restoreState()

        let restored = await renderer2.preferences()
        XCTAssertEqual(restored.readingMode, .paginated)
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.typography.fontFamily, "Georgia")
        XCTAssertEqual(restored.typography.fontSize, 20, accuracy: 0.0001)
    }

    func testVoiceOverForcesScrollModeWithoutLosingPreferredMode() async throws {
        let bridge = MockReflowBridge()
        let renderer = try ContentRenderer(
            book: makeBook(),
            reflowBridge: bridge
        )

        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))
        try await renderer.setReadingMode(.paginated)

        try await renderer.setAccessibility(
            ReaderAccessibilitySettings(
                isVoiceOverEnabled: true,
                forceScrollWhenVoiceOverEnabled: true
            )
        )
        let effectiveWhenVoiceOver = await renderer.readingMode()
        let preferredWhenVoiceOver = await renderer.preferences().readingMode
        XCTAssertEqual(effectiveWhenVoiceOver, .scroll)
        XCTAssertEqual(preferredWhenVoiceOver, .paginated)

        try await renderer.setAccessibility(
            ReaderAccessibilitySettings(
                isVoiceOverEnabled: false,
                forceScrollWhenVoiceOverEnabled: true
            )
        )
        let effectiveAfterVoiceOver = await renderer.readingMode()
        XCTAssertEqual(effectiveAfterVoiceOver, .paginated)
        XCTAssertTrue(bridge.commands.contains(.setReadingMode(.paginated)))
        XCTAssertTrue(bridge.commands.contains(.setReadingMode(.scroll)))
    }

    func testDecorationsAreAppliedAndTapEventsAreStored() async throws {
        let bridge = MockReflowBridge()
        let renderer = try ContentRenderer(
            book: makeBook(),
            reflowBridge: bridge
        )

        try await renderer.renderChapter(at: 0, viewport: Viewport(width: 390, height: 844))

        let decoration = Decoration(
            id: "search-hit-1",
            group: .search,
            locator: Locator(
                sectionIndex: 0,
                sectionHref: "OPS/ch1.xhtml",
                sectionProgression: 0.1,
                totalProgression: 0.05,
                anchor: "note-1",
                cfi: nil,
                textContext: nil
            ),
            style: DecorationStyle(
                backgroundColor: "#ffe58f",
                textColor: "#1a1a1a",
                underlineColor: "#ffb300"
            )
        )
        try await renderer.setDecorations([decoration], in: .search)

        XCTAssertTrue(bridge.commands.contains { command in
            guard case let .setDecorations(values) = command else {
                return false
            }
            return values.contains(where: { $0.id == "search-hit-1" })
        })

        bridge.emit(.decorationTapped(id: "search-hit-1", group: .search))
        try await Task.sleep(nanoseconds: 20_000_000)

        let tap = renderer.lastDecorationTap()
        XCTAssertEqual(tap?.id, "search-hit-1")
        XCTAssertEqual(tap?.group, .search)
        XCTAssertEqual(tap?.locator?.sectionIndex, 0)
    }

    private func makeBook() -> Book {
        Book(
            id: "navigator-book",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "Navigator", authors: ["A"]),
            readingOrder: [
                Chapter(id: "c1", href: "OPS/ch1.xhtml", title: "C1", content: "<h1 id=\"note-1\">One</h1><p>Text</p>"),
                Chapter(id: "c2", href: "OPS/ch2.xhtml", title: "C2", content: "<h1 id=\"note-1\">Two</h1><p>Text</p>"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
    }
}
