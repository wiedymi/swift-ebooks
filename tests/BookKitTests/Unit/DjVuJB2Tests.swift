import XCTest
@testable import BookKit

final class DjVuJB2Tests: XCTestCase {
    func testDecodesSinglePixelMask() throws {
        let image = try DjVuJB2Decoder.decodeImage(
            Data(base64Encoded: "m2v3MA==")!,
            expectedWidth: 4,
            expectedHeight: 4,
            maxOutputBytes: 1_024,
            maxRecords: 100
        )
        XCTAssertEqual(image.mask, [
            0, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        ])
    }

    func testDecodesLosslessSymbolMask() throws {
        let data = Data(base64Encoded: "h7ygmQlSVEBQQRPfo48=")!
        let image = try DjVuJB2Decoder.decodeImage(
            data,
            expectedWidth: 16,
            expectedHeight: 16,
            maxOutputBytes: 1_024 * 1_024,
            maxRecords: 1_000
        )

        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        XCTAssertEqual(image.mask, expectedMask)
        XCTAssertFalse(image.symbols.isEmpty)
    }

    func testDecodesSharedDictionaryAndRequiredDictionaryPage() throws {
        let symbols = try DjVuJB2Decoder.decodeDictionary(
            Data([0xe7, 0x69, 0x4f]),
            maxOutputBytes: 1_024,
            maxRecords: 100
        )
        XCTAssertEqual(symbols, [try DjVuJB2Bitmap(width: 1, height: 1, pixels: [1])])

        let image = try DjVuJB2Decoder.decodeImage(
            Data([0x15, 0x84, 0x04, 0xe3, 0xef]),
            sharedSymbols: symbols,
            expectedWidth: 4,
            expectedHeight: 4,
            maxOutputBytes: 1_024,
            maxRecords: 100
        )
        XCTAssertEqual(image.mask, [
            0, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        ])
        XCTAssertEqual(image.blitCount, 1)
        XCTAssertEqual(image.blitMap[5], 0)
    }

    private var expectedMask: [UInt8] {
        [
            "0000000000000000",
            "0111000001110000",
            "0101000001010000",
            "0111000001110000",
            "0101000001010000",
            "0101000001010000",
            "0000000000000000",
            "0000000000000000",
            "0011100000111000",
            "0010000000100000",
            "0011000000110000",
            "0010000000100000",
            "0011100000111000",
            "0000000000000000",
            "0000000000000000",
            "0000000000000000",
        ].flatMap { row in row.map { $0 == "1" ? 1 : 0 } }
    }
}
