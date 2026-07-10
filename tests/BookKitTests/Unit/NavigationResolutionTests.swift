import XCTest
@testable import BookKit

final class NavigationResolutionTests: XCTestCase {
    func testBookResolvesNavigationHrefAndFragmentToLocator() throws {
        let book = makeBook()

        let locator = try XCTUnwrap(
            book.locator(forNavigationHref: "OPS/Text/ch2.xhtml#note-1")
        )

        XCTAssertEqual(locator.sectionIndex, 1)
        XCTAssertEqual(locator.sectionHref, "OPS/Text/ch2.xhtml")
        XCTAssertEqual(locator.anchor, "note-1")
        XCTAssertEqual(locator.sectionProgression, 0)
    }

    func testBookResolvesChapterRelativeLink() throws {
        let book = makeBook()

        let locator = try XCTUnwrap(
            book.locator(
                forNavigationHref: "ch2.xhtml#note-1",
                relativeTo: "OPS/Text/ch1.xhtml"
            )
        )

        XCTAssertEqual(locator.sectionIndex, 1)
        XCTAssertEqual(locator.anchor, "note-1")
    }

    func testBookResolvesAnchorWithinCurrentChapter() throws {
        let book = makeBook()

        let locator = try XCTUnwrap(
            book.locator(
                forNavigationHref: "#local-note",
                relativeTo: "OPS/Text/ch2.xhtml"
            )
        )

        XCTAssertEqual(locator.sectionIndex, 1)
        XCTAssertEqual(locator.anchor, "local-note")
    }

    private func makeBook() -> Book {
        Book(
            id: "navigation",
            format: .epub,
            version: "3",
            metadata: Metadata(title: "Navigation", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "OPS/Text/ch1.xhtml", title: "One", content: "One"),
                Chapter(id: "c2", href: "OPS/Text/ch2.xhtml", title: "Two", content: "Two"),
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
