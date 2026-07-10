import XCTest
@testable import BookKit

final class CompressedFB2Tests: XCTestCase {
    func testOpensSingleFB2FromZip() async throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description><title-info><book-title>Zipped Book</book-title><lang>en</lang></title-info></description>
          <body><section id="one"><title><p>One</p></title><p>Hello zipped world.</p></section></body>
        </FictionBook>
        """
        let zip = try ArchiveTestSupport.makeZIP([
            ("book.fb2", Data(xml.utf8)),
            ("metadata.txt", Data("ignored".utf8)),
        ])

        let book = try await FB2Parser().parse(
            source: .data(zip, fileName: "book.fb2.zip"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.format, .fb2)
        XCTAssertEqual(book.metadata.title, "Zipped Book")
        XCTAssertTrue(book.readingOrder[0].content.contains("Hello zipped world"))
        XCTAssertEqual(book.rawExtensions["bookkit:container"], "fb2.zip")
    }

    func testRejectsZipWithMultipleFB2Documents() async throws {
        let payload = Data("<FictionBook/>".utf8)
        let zip = try ArchiveTestSupport.makeZIP([("one.fb2", payload), ("two.fb2", payload)])

        do {
            _ = try await FB2Parser().parse(
                source: .data(zip, fileName: "ambiguous.fb2.zip"),
                options: OpenOptions()
            )
            XCTFail("Expected invalidContainer")
        } catch BookError.invalidContainer(_) {
            // Expected.
        }
    }
}
