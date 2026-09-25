import XCTest
@testable import BookKit

final class KindleResourceLimitTests: XCTestCase {
    func testPalmDOCExpansionStopsAtResourceLimit() async throws {
        var data = Data(repeating: 0, count: 94 + 256)
        data.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        writeBigEndian(2, into: &data, at: 76, bytes: 2)
        writeBigEndian(94, into: &data, at: 78, bytes: 4)
        writeBigEndian(350, into: &data, at: 86, bytes: 4)
        let header = 94
        writeBigEndian(2, into: &data, at: header, bytes: 2)
        writeBigEndian(4, into: &data, at: header + 4, bytes: 4)
        writeBigEndian(1, into: &data, at: header + 8, bytes: 2)
        data.replaceSubrange((header + 16)..<(header + 20), with: Data("MOBI".utf8))
        writeBigEndian(232, into: &data, at: header + 20, bytes: 4)
        writeBigEndian(65_001, into: &data, at: header + 28, bytes: 4)
        writeBigEndian(6, into: &data, at: header + 36, bytes: 4)
        data.append(contentsOf: [0x41, 0x80, 0x09, 0x80, 0x09, 0x80, 0x09])

        do {
            _ = try await Book.open(
                source: .data(data, fileName: "expanded.mobi"),
                options: OpenOptions(maxResourceBytes: 8)
            )
            XCTFail("Expected the decoded text limit")
        } catch let BookError.malformedDocument(message) {
            XCTAssertTrue(message.contains("resource limit"))
        }
    }

    private func writeBigEndian(_ value: Int, into data: inout Data, at offset: Int, bytes: Int) {
        for index in 0..<bytes {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> ((bytes - index - 1) * 8))
        }
    }
}
