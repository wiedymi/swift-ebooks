import XCTest
@testable import BookKit

final class ReaderTests: XCTestCase {
    func testReaderPagingAndBounds() async throws {
        let chapterText = String(repeating: "a", count: 2000)
        let book = Book(
            id: "test",
            format: .epub,
            version: "1.0",
            metadata: Metadata(title: "T", authors: ["A"]),
            readingOrder: [
                Chapter(id: "c1", href: "c1.xhtml", title: "C1", content: chapterText),
                Chapter(id: "c2", href: "c2.xhtml", title: "C2", content: chapterText),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let reader = ReaderStateActor(book: book, pageCharacterCount: 500)

        let start = await reader.position
        XCTAssertEqual(start.spineIndex, 0)
        XCTAssertEqual(start.progression, 0)

        try await reader.nextPage()
        let p1 = await reader.position
        XCTAssertEqual(p1.spineIndex, 0)
        XCTAssertGreaterThan(p1.progression, 0)

        try await reader.go(to: Position(spineIndex: 1, progression: 0.25))
        let moved = await reader.position
        XCTAssertEqual(moved.spineIndex, 1)
        XCTAssertEqual(moved.progression, 0.25, accuracy: 0.0001)

        try await reader.previousPage()
        let p2 = await reader.position
        XCTAssertEqual(p2.spineIndex, 1)
        XCTAssertLessThan(p2.progression, 0.25)
    }

    func testReaderClampsOutOfRangePosition() async throws {
        let book = Book(
            id: "test2",
            format: .epub,
            version: "1.0",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1.xhtml", title: nil, content: "abc"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let reader = ReaderStateActor(book: book, pageCharacterCount: 10)
        try await reader.go(to: Position(spineIndex: 999, progression: 9.0))

        let pos = await reader.position
        XCTAssertEqual(pos.spineIndex, 0)
        XCTAssertEqual(pos.progression, 1.0)
    }
}
