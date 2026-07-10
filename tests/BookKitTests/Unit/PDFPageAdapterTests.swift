import XCTest
@testable import BookKit

final class PDFPageAdapterTests: XCTestCase {
    func testPageIndexAndPositionMapping() {
        let book = Book(
            id: "pdf",
            format: .pdf,
            version: "1.7",
            metadata: Metadata(title: "PDF", authors: []),
            readingOrder: [
                Chapter(id: "p1", href: "pdf://page/1", title: "Page 1", content: "1"),
                Chapter(id: "p2", href: "pdf://page/2", title: "Page 2", content: "2"),
                Chapter(id: "p3", href: "pdf://page/3", title: "Page 3", content: "3"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let adapter = PDFPageAdapter(book: book)
        XCTAssertEqual(adapter.pageCount, 3)

        XCTAssertEqual(adapter.pageIndex(for: Position(spineIndex: 2, progression: 0.5)), 2)
        XCTAssertEqual(adapter.pageIndex(for: Position(spineIndex: 999, progression: 0.5)), 2)
        XCTAssertEqual(adapter.pageIndex(for: Position(spineIndex: -10, progression: 0.5)), 0)

        XCTAssertEqual(adapter.position(forPageIndex: 0).spineIndex, 0)
        XCTAssertEqual(adapter.position(forPageIndex: 999).spineIndex, 2)
    }
}
