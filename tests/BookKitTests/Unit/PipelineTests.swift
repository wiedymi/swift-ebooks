import XCTest
@testable import BookKit

final class PipelineTests: XCTestCase {
    func testSanitizeContentRemovesScriptsAndHandlers() {
        let input = #"<p onclick=\"alert(1)\">Hello</p><script>alert(2)</script><a href=\"javascript:evil()\">x</a>"#
        let output = SanitizeContent.run(input)

        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("onclick="))
        XCTAssertFalse(output.lowercased().contains("javascript:"))
    }

    func testNormalizeIsIdempotent() {
        let book = Book(
            id: "id",
            format: .epub,
            version: "1.0",
            metadata: Metadata(title: "  Title  ", authors: ["  Author Name  "]),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: "  Ch 1  ", content: "<script>x</script> Hello    world"),
            ],
            assets: [],
            tableOfContents: [TOCNode(title: "  Ch 1  ", href: "c1")],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let normalized1 = Normalize.run(book)
        let normalized2 = Normalize.run(normalized1)
        XCTAssertEqual(normalized1, normalized2)
    }

    func testSearchIndexFindsQuery() {
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [
                Chapter(id: "c1", href: "c1", title: nil, content: "Short Works by Epictetus"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let index = SearchIndex(book: book)
        let results = index.find("short works")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.chapterID, "c1")
    }
}
