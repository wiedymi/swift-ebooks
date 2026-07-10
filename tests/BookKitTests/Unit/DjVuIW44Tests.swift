import XCTest
@testable import BookKit

final class DjVuIW44Tests: XCTestCase {
    func testDecodesConstantGrayscaleIW44Image() throws {
        let payload = Data([
            0x00, 0x64, 0x81, 0x02, 0x00, 0x08, 0x00, 0x08, 0x00,
            0xff, 0xff, 0xe2, 0xfb,
        ])
        let image = try DjVuIW44Decoder.decode(
            chunks: [payload],
            maxOutputBytes: 1_024 * 1_024
        )
        XCTAssertEqual(
            stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] },
            [UInt8](repeating: 128, count: 64)
        )
    }

    func testDecodesPublishedIW44ArithmeticAndWaveletLayout() throws {
        // An 8x8 color gradient encoded by the reference command-line encoder.
        // The expected pixels were produced independently by its renderer.
        let documentData = Data(
            base64Encoded: "QVQmVEZPUk0AAABaREpWVUlORk8AAAAKAAgACBgAZAAWAUJHNDQAAAA8AGQBAgAIAAiK8uMOaWvfVO/8Z4j6Rb35qRkbqggtto4uXKUayxQ6Hka9scNCGWI9eOG61t44IEPQI5V/"
        )!
        let document = try DjVuIFFParser.parse(documentData, options: OpenOptions())
        let chunks = document.pages[0].chunks
            .filter { $0.id == "BG44" }
            .map { $0.payload(in: documentData) }

        let image = try DjVuIW44Decoder.decode(chunks: chunks, maxOutputBytes: 1_024 * 1_024)

        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
        let expectedPPM = Data(
            base64Encoded: "UDYKOCA4CjI1NQrwFADvVADtlQD00wDq/w2l/x5S/x87/xvwCjjvSjjtizf0yzDq/y2l/zdS/zM7/y/1Bn71R3/yhn75xnvu/3uo/3pV/24//4H7A8f6Qsb4g8f/wsfz/8ep/71a/6s//9LFAPHEPu/Ef+zJwOnA/+mJ//FA/+k//+59AP99Pv98ff+Cv/t8//hQ//8///8//+M+Af8/QP8/gP9CwP8///0j/+U5/8w5/5YABPYAQvsAg/4Dwf8C//8R/8Uv/4gv/0I="
        )!
        let expectedRGB = expectedPPM.dropFirst(Data("P6\n8 8\n255\n".utf8).count)
        let actualRGB = stride(from: 0, to: image.rgba.count, by: 4).flatMap {
            Array(image.rgba[$0...($0 + 2)])
        }
        assertPixels(actualRGB, closeTo: Array(expectedRGB), tolerance: 6)
        XCTAssertTrue(stride(from: 3, to: image.rgba.count, by: 4).allSatisfy {
            image.rgba[$0] == 255
        })
    }

    func testDecodesGrayscaleIW44WaveletDetails() throws {
        let documentData = Data(
            base64Encoded: "QVQmVEZPUk0AAAA+REpWVUlORk8AAAAKAAgACBgAZAAWAUJHNDQAAAAgAGSBAgAIAAgA8u+h00+3HAekvu+HFp0aCa8nz17tBt8="
        )!
        let document = try DjVuIFFParser.parse(documentData, options: OpenOptions())
        let chunks = document.pages[0].chunks
            .filter { $0.id == "BG44" }
            .map { $0.payload(in: documentData) }
        let image = try DjVuIW44Decoder.decode(chunks: chunks, maxOutputBytes: 1_024 * 1_024)
        let expectedPGM = Data(
            base64Encoded: "UDUKOCA4CjI1NQoAHz9cgcH//xMzU3CV1f//IkJifqPm//8wUXGNsvb//0BhgZ7B////UHGSr9D///9fgaPA3////26Rs9Lu////"
        )!
        let expected = expectedPGM.dropFirst(Data("P5\n8 8\n255\n".utf8).count)
        let actual = stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] }
        assertPixels(actual, closeTo: Array(expected), tolerance: 5)
    }

    func testDecodesEarlyProgressiveGrayscaleSlice() throws {
        let documentData = Data(
            base64Encoded: "QVQmVEZPUk0AAAAqREpWVUlORk8AAAAKAAgACBgAZAAWAUJHNDQAAAAMADKBAgAIAAgA8u+f"
        )!
        let document = try DjVuIFFParser.parse(documentData, options: OpenOptions())
        let chunks = document.pages[0].chunks
            .filter { $0.id == "BG44" }
            .map { $0.payload(in: documentData) }
        let image = try DjVuIW44Decoder.decode(chunks: chunks, maxOutputBytes: 1_024 * 1_024)
        let expectedPGM = Data(
            base64Encoded: "UDUKOCA4CjI1NQpNeaXX/f39/U15pdf9/f39TXml1/39/f1NeaXX/f39/U15pdf9/f39TXml1/39/f1NeaXX/f39/U15pdf9/f39"
        )!
        let expected = expectedPGM.dropFirst(Data("P5\n8 8\n255\n".utf8).count)
        let actual = stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] }
        XCTAssertEqual(Data(actual), Data(expected))
    }

    private func assertPixels(
        _ actual: [UInt8],
        closeTo expected: [UInt8],
        tolerance: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        guard actual.count == expected.count else { return }
        let differences = zip(actual, expected).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(
            differences.reduce(0, +),
            actual.count * 2,
            "Mean pixel error exceeds two levels",
            file: file,
            line: line
        )
    }
}
