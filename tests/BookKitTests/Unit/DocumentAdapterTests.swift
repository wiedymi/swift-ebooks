import XCTest
@testable import BookKit

final class DocumentAdapterTests: XCTestCase {
    func testPlainTextAdapterEscapesMarkupAndPreservesParagraphs() async throws {
        let text = "A Plain Book\n\nFirst <unsafe> paragraph.\nStill first.\n\nSecond paragraph."
        let book = try await Book.open(
            source: .data(Data(text.utf8), fileName: "plain.txt")
        )

        XCTAssertEqual(book.format, .text)
        XCTAssertEqual(book.metadata.title, "A Plain Book")
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertTrue(book.readingOrder[0].content.contains("&lt;unsafe&gt;"))
        XCTAssertTrue(book.readingOrder[0].content.contains("<p>"))
        XCTAssertFalse(book.readingOrder[0].content.contains("<unsafe>"))
    }

    func testHTMLAdapterBuildsNestedTOCAndKeepsLinksForPolicyLayer() async throws {
        let html = """
        <!doctype html><html><head><title>HTML Book</title></head><body>
        <h1>Part One</h1><p>Read <a href="chapter-two.html">next</a>.</p>
        <h2 id="details">Details</h2><p>Body</p>
        </body></html>
        """
        let book = try await Book.open(
            source: .data(Data(html.utf8), fileName: "book.html")
        )

        XCTAssertEqual(book.format, .html)
        XCTAssertEqual(book.metadata.title, "HTML Book")
        XCTAssertEqual(book.tableOfContents.count, 1)
        XCTAssertEqual(book.tableOfContents[0].title, "Part One")
        XCTAssertEqual(book.tableOfContents[0].children.map(\.title), ["Details"])
        XCTAssertTrue(book.readingOrder[0].content.contains("id=\"part-one\""))
        XCTAssertTrue(book.readingOrder[0].content.contains("href=\"chapter-two.html\""))
    }

    func testMarkdownAdapterRendersStructureLinksCodeAndTOC() async throws {
        let markdown = """
        # Markdown Book

        Intro with **bold** and [BookKit](https://example.com).

        ## Chapter One

        - first
        - second

        ```swift
        let value = 1 < 2
        ```
        """
        let book = try await Book.open(
            source: .data(Data(markdown.utf8), fileName: "book.md")
        )

        XCTAssertEqual(book.format, .markdown)
        XCTAssertEqual(book.metadata.title, "Markdown Book")
        XCTAssertEqual(book.tableOfContents[0].children.map(\.title), ["Chapter One"])
        XCTAssertTrue(book.readingOrder[0].content.contains("<strong>bold</strong>"))
        XCTAssertTrue(book.readingOrder[0].content.contains("<ul>"))
        XCTAssertTrue(book.readingOrder[0].content.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(book.readingOrder[0].content.contains("1 &lt; 2"))
        XCTAssertTrue(book.readingOrder[0].content.contains("href=\"https://example.com\""))
    }

    func testInvalidTextEncodingIsRejected() async throws {
        do {
            _ = try await TextDocumentParser().parse(
                source: .data(Data([0xff, 0xff, 0xff]), fileName: "bad.txt"),
                options: OpenOptions()
            )
            XCTFail("Expected malformedDocument")
        } catch BookError.malformedDocument(_) {
            // Expected.
        }
    }
}
