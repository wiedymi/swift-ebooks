import XCTest
@testable import BookKit

final class FormatSnifferTests: XCTestCase {
    func testDetectByFileExtension() throws {
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.epub"), .epub)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.fb2"), .fb2)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.mobi"), .mobi)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.azw3"), .azw3)
        XCTAssertEqual(FormatSniffer.detect(fileName: "sample.pdf"), .pdf)
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
}
