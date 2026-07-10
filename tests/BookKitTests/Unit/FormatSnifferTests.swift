import XCTest
@testable import BookKit

final class FormatSnifferTests: XCTestCase {
    func testDetectByFileExtension() throws {
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.epub"), .epub)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.fb2"), .fb2)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.fb2.zip"), .fb2)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.mobi"), .mobi)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.azw3"), .azw3)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.pdf"), .pdf)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.cbz"), .cbz)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.txt"), .text)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.html"), .html)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.md"), .markdown)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.readium-audiobook"), .audiobook)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.audiobook"), .audiobook)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.lpf"), .audiobook)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.m4b"), .audiobook)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.djvu"), .djvu)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.djv"), .djvu)
    }

    func testDetectByMagicBytes() throws {
        XCTAssertEqual(FormatSniffer.detect(data: Data("%PDF-1.7".utf8), fileName: nil), .pdf)
        XCTAssertEqual(FormatSniffer.detect(data: Data("BOOKMOBI".utf8), fileName: nil), .mobi)

        let fb2 = "<?xml version=\"1.0\"?><FictionBook></FictionBook>"
        XCTAssertEqual(FormatSniffer.detect(data: Data(fb2.utf8), fileName: nil), .fb2)
    }

    func testExtensionWinsBetweenMobiAndAzw3() throws {
        let mobiMagic = Data("BOOKMOBI".utf8)
        XCTAssertEqual(FormatSniffer.detect(data: mobiMagic, fileName: "x.azw3"), .azw3)
    }

    func testDetectsDjVuAndCommonTextMagic() {
        XCTAssertEqual(
            FormatSniffer.detect(data: Data("AT&TFORM\0\0\0\0DJVU".utf8), fileName: nil),
            .djvu
        )
        XCTAssertEqual(
            FormatSniffer.detect(data: Data("SDJV\0\0\0\0".utf8), fileName: nil),
            .djvu
        )
        XCTAssertEqual(
            FormatSniffer.detect(data: Data("<!doctype html><html><body>Book</body></html>".utf8), fileName: nil),
            .html
        )
        XCTAssertEqual(
            FormatSniffer.detect(data: Data("# Chapter\n\nBook text".utf8), fileName: nil),
            .markdown
        )
    }
}
