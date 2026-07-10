import XCTest
@testable import BookKit

final class CorpusE2ETests: XCTestCase {
    func testManifestLoadsAndCoversV1Formats() throws {
        let entries = try CorpusManifest.load()
        XCTAssertGreaterThanOrEqual(entries.count, 5)

        let formats = Set(entries.map(\.format))
        XCTAssertTrue(formats.contains(.epub))
        XCTAssertTrue(formats.contains(.fb2))
        XCTAssertTrue(formats.contains(.mobi))
        XCTAssertTrue(formats.contains(.azw3))
        XCTAssertTrue(formats.contains(.pdf))

        for entry in entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path), "Missing corpus file for \(entry.id)")
        }
    }

    func testCanOpenEveryCorpusBook() async throws {
        let entries = try CorpusManifest.load()
        let options = OpenOptions(allowsNetwork: false, tempDirectory: nil, fileAccess: SandboxFileAccessPolicy())

        for entry in entries {
            let book = try await Book.open(from: entry.fileURL, options: options)
            XCTAssertEqual(book.format, entry.format, "Unexpected format for \(entry.id)")
            XCTAssertFalse(book.readingOrder.isEmpty, "Reading order should not be empty for \(entry.id)")

            if entry.format != .pdf {
                XCTAssertFalse(book.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Title should not be empty for \(entry.id)")
            }
        }
    }

    func testSearchWorksAcrossEpubMobiAzw3Fixtures() async throws {
        let entries = try CorpusManifest.load().filter {
            $0.format == .epub || $0.format == .mobi || $0.format == .azw3
        }
        let options = OpenOptions(allowsNetwork: false, tempDirectory: nil, fileAccess: SandboxFileAccessPolicy())

        for entry in entries {
            let book = try await Book.open(from: entry.fileURL, options: options)
            let results = try await book.search("Short Works")
            XCTAssertFalse(results.isEmpty, "Search returned no results for \(entry.id)")
        }
    }

    func testEpubCorpusPreservesMarkupAndMapsAssets() async throws {
        let entry = try XCTUnwrap(
            CorpusManifest.load().first(where: { $0.format == .epub }),
            "Expected at least one EPUB corpus entry"
        )
        let book = try await Book.open(from: entry.fileURL, options: OpenOptions(allowsNetwork: false))

        XCTAssertTrue(
            book.readingOrder.contains(where: { $0.content.contains("<") && $0.content.contains(">") }),
            "Expected EPUB chapters to preserve normalized markup content"
        )
        XCTAssertFalse(book.assets.isEmpty, "Expected EPUB manifest assets")
        XCTAssertTrue(
            book.assets.contains(where: { $0.data != nil }),
            "Expected at least one EPUB asset payload to be loaded"
        )
    }

    func testFB2CorpusExtractsStructuredAuthorMetadata() async throws {
        let entry = try XCTUnwrap(
            CorpusManifest.load().first(where: { $0.format == .fb2 }),
            "Expected at least one FB2 corpus entry"
        )
        let book = try await Book.open(from: entry.fileURL, options: OpenOptions(allowsNetwork: false))

        XCTAssertEqual(book.metadata.title, "Вторая мировая война")
        XCTAssertTrue(book.metadata.authors.contains("Уинстон Черчилль"))
    }
}
