import XCTest
@testable import BookKit

final class CBZParserTests: XCTestCase {
    func testParsesNaturalPageOrderComicInfoRTLSpreadsCoverAndBookmarks() async throws {
        let comicInfo = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo>
          <Title>Issue One</Title>
          <Series>Example Series</Series>
          <Number>1</Number>
          <Writer>Ada Author, Bob Writer</Writer>
          <Publisher>Example Press</Publisher>
          <LanguageISO>ja</LanguageISO>
          <Year>2026</Year><Month>7</Month><Day>10</Day>
          <Manga>YesAndRightToLeft</Manga>
          <Pages>
            <Page Image="0" Type="FrontCover" ImageWidth="1200" ImageHeight="1800"/>
            <Page Image="1" Bookmark="Chapter One"/>
            <Page Image="2" DoublePage="true" ImageWidth="2400" ImageHeight="1800"/>
          </Pages>
        </ComicInfo>
        """
        let zip = try ArchiveTestSupport.makeZIP([
            ("pages/010.jpg", Data([0xff, 0xd8, 10])),
            ("pages/002.jpg", Data([0xff, 0xd8, 2])),
            ("pages/001.jpg", Data([0xff, 0xd8, 1])),
            ("__MACOSX/._001.jpg", Data([0xff, 0xd8, 0])),
            ("ComicInfo.xml", Data(comicInfo.utf8)),
        ])

        let book = try await CBZParser().parse(
            source: .data(zip, fileName: "issue.cbz"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.format, .cbz)
        XCTAssertEqual(book.metadata.title, "Issue One")
        XCTAssertEqual(book.metadata.authors, ["Ada Author", "Bob Writer"])
        XCTAssertEqual(book.metadata.language, "ja")
        XCTAssertEqual(book.metadata.publisher, "Example Press")
        XCTAssertEqual(book.metadata.publicationDate, "2026-07-10")
        XCTAssertEqual(book.readingOrder.map(\.href), ["pages/001.jpg", "pages/002.jpg", "pages/010.jpg"])
        XCTAssertEqual(book.presentation.layout, .fixed)
        XCTAssertEqual(book.presentation.readingProgression, .rightToLeft)
        XCTAssertEqual(book.presentation.coverPageIndex, 0)
        XCTAssertEqual(book.readingOrder[0].page?.isCover, true)
        XCTAssertEqual(book.readingOrder[0].page?.pixelWidth, 1200)
        XCTAssertEqual(book.readingOrder[1].page?.side, .right)
        XCTAssertEqual(book.readingOrder[2].page?.isSpread, true)
        XCTAssertEqual(book.tableOfContents.map(\.title), ["Cover", "Chapter One"])
        XCTAssertEqual(book.assets.count, 3)
    }

    func testRejectsArchiveWithoutImages() async throws {
        let zip = try ArchiveTestSupport.makeZIP([("README.txt", Data("nothing".utf8))])
        do {
            _ = try await CBZParser().parse(
                source: .data(zip, fileName: "empty.cbz"),
                options: OpenOptions()
            )
            XCTFail("Expected malformedDocument")
        } catch BookError.malformedDocument(_) {
            // Expected.
        }
    }
}
