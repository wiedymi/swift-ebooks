import XCTest
@testable import BookKit

final class PublicationModelTests: XCTestCase {
    func testBookInitializerRemainsReflowableByDefault() {
        let book = Book(
            id: "book",
            format: .epub,
            version: "3.3",
            metadata: Metadata(title: "Book", authors: []),
            readingOrder: [
                Chapter(id: "chapter", href: "chapter.xhtml", title: nil, content: "Hello"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        XCTAssertEqual(book.presentation.layout, .reflowable)
        XCTAssertEqual(book.presentation.readingProgression, .leftToRight)
        XCTAssertEqual(book.presentation.spread, .auto)
    }

    func testFixedPageAndTimedMediaPropertiesAreTyped() {
        let page = Chapter(
            id: "page-1",
            href: "001.jpg",
            title: "Page 1",
            content: "",
            resourceID: "image-1",
            mediaType: "image/jpeg",
            page: PagePresentation(side: .right, isCover: true, pixelWidth: 1200, pixelHeight: 1800)
        )
        let track = Chapter(
            id: "track-1",
            href: "chapter.m4a",
            title: "Chapter 1",
            content: "",
            mediaType: "audio/mp4",
            audio: AudioPresentation(duration: 42, clipBegin: 3, clipEnd: 45)
        )

        XCTAssertEqual(page.resourceID, "image-1")
        XCTAssertEqual(page.page?.side, .right)
        XCTAssertEqual(page.page?.isCover, true)
        XCTAssertEqual(track.audio?.duration, 42)
        XCTAssertEqual(track.audio?.clipBegin, 3)
        XCTAssertEqual(track.audio?.clipEnd, 45)
    }

    func testPositionCanRepresentTimedPlayback() {
        let position = Position(spineIndex: 2, progression: 0.25, timestamp: 15.5)
        XCTAssertEqual(position.timestamp, 15.5)
    }
}
