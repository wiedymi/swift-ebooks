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

    func testBookResolvesExactInternalCustomSchemeHref() throws {
        let book = Book(
            id: "pdf-navigation",
            format: .pdf,
            version: "1.7",
            metadata: Metadata(title: "PDF", authors: []),
            readingOrder: [
                Chapter(id: "p1", href: "pdf://page/1", title: "One", content: ""),
                Chapter(id: "p2", href: "pdf://page/2", title: "Two", content: ""),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .fixed)
        )

        XCTAssertEqual(
            book.locator(forNavigationHref: "pdf://page/2")?.sectionIndex,
            1
        )
        XCTAssertNil(book.locator(forNavigationHref: "https://unrelated.example/page"))
    }

    func testAudiobookTOCMediaFragmentResolvesTimestampAndProgression() throws {
        let book = Book(
            id: "audio-navigation",
            format: .audiobook,
            version: "1",
            metadata: Metadata(title: "Audio", authors: []),
            readingOrder: [
                Chapter(
                    id: "track",
                    href: "audio/track.mp3",
                    title: "Track",
                    content: "",
                    mediaType: "audio/mpeg",
                    audio: AudioPresentation(duration: 120, clipBegin: 10, clipEnd: 130)
                ),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook)
        )

        let locator = try XCTUnwrap(
            book.locator(forNavigationHref: "audio/track.mp3#t=npt:01:10")
        )

        XCTAssertEqual(locator.timestamp, 70)
        XCTAssertEqual(locator.sectionProgression, 0.5, accuracy: 0.0001)
    }

    func testAudiobookLocatorUsesDurationWeightedBookProgress() {
        let book = Book(
            id: "weighted-audio",
            format: .audiobook,
            version: "1",
            metadata: Metadata(title: "Audio", authors: []),
            readingOrder: [
                Chapter(
                    id: "short",
                    href: "short.mp3",
                    title: nil,
                    content: "",
                    audio: AudioPresentation(duration: 100)
                ),
                Chapter(
                    id: "long",
                    href: "long.mp3",
                    title: nil,
                    content: "",
                    audio: AudioPresentation(duration: 300)
                ),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook)
        )

        let locator = book.locator(
            for: Position(spineIndex: 1, progression: 0.5, timestamp: 150)
        )

        XCTAssertEqual(locator.totalProgression, 0.625, accuracy: 0.0001)
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
