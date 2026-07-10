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

    func testSanitizeContentBlocksImplicitNetworkResourcesButKeepsLinks() {
        let input = #"<img src="https://cdn.example/cover.jpg"><a href="https://example.com">Open</a><iframe src="https://tracker.example"></iframe>"#
        let output = SanitizeContent.run(input)

        XCTAssertFalse(output.contains("cdn.example"))
        XCTAssertFalse(output.contains("iframe"))
        XCTAssertTrue(output.contains(#"href="https://example.com""#))
    }

    func testSanitizeContentAllowsOptedInNetworkResources() {
        let input = #"<img src="https://cdn.example/cover.jpg">"#
        let output = SanitizeContent.run(input, allowsNetwork: true)

        XCTAssertTrue(output.contains("https://cdn.example/cover.jpg"))
    }

    func testSanitizeCSSBlocksRemoteImportsAndURLsByDefault() {
        let input = #"@import "https://cdn.example/book.css"; p { background: url(https://cdn.example/bg.png); }"#
        let output = SanitizeContent.css(input)

        XCTAssertFalse(output.contains("cdn.example"))
        XCTAssertTrue(output.contains("blocked-remote"))
    }

    func testNormalizePreservesPreformattedWhitespace() {
        let content = "<pre>line one\n    indented line</pre>"
        let book = Book(
            id: "pre",
            format: .epub,
            version: "3",
            metadata: Metadata(title: "Pre", authors: []),
            readingOrder: [Chapter(id: "one", href: "one.xhtml", title: nil, content: content)],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        XCTAssertEqual(Normalize.run(book).readingOrder[0].content, content)
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
