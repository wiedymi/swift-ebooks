import XCTest
@testable import BookKit

final class DjVuBZZTests: XCTestCase {
    // Directory stream from the public DjVu v3 electronic-publishing sample.
    private let directoryStream = Data(
        base64Encoded: """
        //85v4ohn6rYo9+rxOt1hkRmUgAbSGdRCIuxP0BYd7y8jASF7yeTQU/Hwso6BMYjmUG1y9kxiYcMZcqF
        lzke8N04sRXtxbGCGFgNc3Iwu+7FJIWdrZoxdgc1Pw==
        """,
        options: .ignoreUnknownCharacters
    )!

    func testDecodesSpecBZZDirectoryStream() throws {
        let decoded = try DjVuBZZDecoder.decode(directoryStream, maxOutputBytes: 4_096)
        let componentSizes = [
            6_218, 8_124, 8_562, 8_120, 7_898, 7_670, 7_656,
            17_645, 41_963, 53_081, 59_754, 7_899, 5_994,
        ]
        var expectedPrefix = Data()
        for size in componentSizes {
            expectedPrefix.appendUInt24(size)
        }
        expectedPrefix.append(0)
        expectedPrefix.append(contentsOf: repeatElement(UInt8(1), count: 12))

        XCTAssertEqual(decoded.prefix(expectedPrefix.count), expectedPrefix)
        XCTAssertTrue(String(decoding: decoded, as: UTF8.self).contains(".djvu"))
    }

    func testRejectsOutputBeyondConfiguredLimit() throws {
        XCTAssertThrowsError(
            try DjVuBZZDecoder.decode(directoryStream, maxOutputBytes: 32)
        ) { error in
            guard case BookError.invalidContainer(let message) = error else {
                return XCTFail("Expected invalidContainer, got \(error)")
            }
            XCTAssertTrue(message.contains("limit"))
        }
    }
}

private extension Data {
    mutating func appendUInt24(_ value: Int) {
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
