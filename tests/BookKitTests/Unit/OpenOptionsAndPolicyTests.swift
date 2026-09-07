import Darwin
import XCTest
@testable import BookKit

final class OpenOptionsAndPolicyTests: XCTestCase {
    func testOpenOptionsDefaults() {
        let options = OpenOptions()
        XCTAssertFalse(options.allowsNetwork)
        XCTAssertNil(options.tempDirectory)
        XCTAssertGreaterThan(options.maxSourceBytes, 0)
        XCTAssertGreaterThan(options.maxResourceBytes, 0)
    }

    func testSourceSizeLimitIsEnforced() async {
        let source = BookSource.data(Data(repeating: 0, count: 5), fileName: "large.epub")
        do {
            _ = try await source.loadData(options: OpenOptions(maxSourceBytes: 4))
            XCTFail("Expected size limit failure")
        } catch BookError.io { } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testBookParsingLeavesMainActor() async throws {
        let book = try await Book.open(
            source: .data(Data("%PDF-smoke".utf8), fileName: "smoke.pdf"),
            registry: ParserRegistry(parsers: [NonMainThreadPDFParser()])
        )
        XCTAssertEqual(book.id, "background-parser")
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

    func testBookSourceDataProviderLoadsData() async throws {
        let payload = Data([1, 2, 3, 4, 5])
        let source = BookSource.dataProvider(fileName: "sample.epub") {
            payload
        }

        let data = try await source.loadData(options: OpenOptions())
        XCTAssertEqual(data, payload)
    }
}

private struct NonMainThreadPDFParser: BookParser {
    let formats: Set<BookFormat> = [.pdf]

    func parse(source _: BookSource, options _: OpenOptions) async throws -> Book {
        if pthread_main_np() != 0 {
            throw BookError.io("Parser ran on the main thread")
        }
        return Book(
            id: "background-parser",
            format: .pdf,
            version: "1",
            metadata: Metadata(title: "Background", authors: []),
            readingOrder: [
                Chapter(id: "one", href: "pdf://page/1", title: "One", content: "One"),
            ],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
    }
}
