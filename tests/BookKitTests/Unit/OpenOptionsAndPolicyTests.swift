import XCTest
@testable import BookKit

final class OpenOptionsAndPolicyTests: XCTestCase {
    func testOpenOptionsDefaults() {
        let options = OpenOptions()
        XCTAssertFalse(options.allowsNetwork)
        XCTAssertNil(options.tempDirectory)
    }

    func testSandboxPolicyAllowsReadingExistingFile() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")

        guard let payload = "hello".data(using: .utf8) else {
            XCTFail("Failed to encode test payload")
            return
        }
        try payload.write(to: temp)

        let policy = SandboxFileAccessPolicy()
        let text = try policy.withReadAccess(to: temp) { scopedURL in
            let data = try Data(contentsOf: scopedURL)
            return String(data: data, encoding: .utf8)
        }

        XCTAssertEqual(text, "hello")
    }

    func testBookSourceStreamProviderLoadsData() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let source = BookSource.stream(fileName: "sample.epub") {
            payload
        }

        let data = try source.loadData(options: OpenOptions())
        XCTAssertEqual(data, payload)
    }
}
