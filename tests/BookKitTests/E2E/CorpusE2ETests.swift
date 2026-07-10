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

    func testCorpusBookIdentifiersAreStableAcrossReopen() async throws {
        let options = OpenOptions(allowsNetwork: false)
        for entry in try CorpusManifest.load() {
            let first = try await Book.open(from: entry.fileURL, options: options)
            let second = try await Book.open(from: entry.fileURL, options: options)
            XCTAssertEqual(first.id, second.id, "Unstable identifier for \(entry.id)")
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

    func testKindleCorpusDecodesPalmDOCFlowsMetadataAndResources() async throws {
        let entries = try CorpusManifest.load()
        let mobiEntry = try XCTUnwrap(entries.first(where: { $0.format == .mobi }))
        let azw3Entry = try XCTUnwrap(entries.first(where: { $0.format == .azw3 }))
        let options = OpenOptions(allowsNetwork: false)

        let mobi = try await Book.open(from: mobiEntry.fileURL, options: options)
        XCTAssertEqual(mobi.metadata.title, "Short Works")
        XCTAssertTrue(mobi.metadata.authors.contains("Epictetus"))
        XCTAssertGreaterThanOrEqual(mobi.assets.count, 4)
        XCTAssertTrue(mobi.readingOrder[0].content.contains("Of things some are in our power"))
        XCTAssertTrue(mobi.readingOrder[0].content.contains("bookkit://asset/kindle-image-4"))
        XCTAssertTrue(mobi.readingOrder[0].content.contains("href=\"#filepos"))
        XCTAssertTrue(mobi.readingOrder[0].content.contains("id=\"filepos"))
        XCTAssertFalse(mobi.readingOrder[0].content.contains("\0"))
        XCTAssertGreaterThan(mobi.tableOfContents.count, 10)

        let azw3 = try await Book.open(from: azw3Entry.fileURL, options: options)
        XCTAssertEqual(azw3.metadata.title, "Short Works")
        XCTAssertGreaterThan(azw3.readingOrder.count, 3)
        XCTAssertGreaterThanOrEqual(azw3.assets.count, 4)
        XCTAssertTrue(azw3.readingOrder.contains(where: {
            $0.content.contains("Of things some are in our power")
        }))
        XCTAssertTrue(azw3.readingOrder.contains(where: {
            $0.content.contains("data-bookkit-publication")
        }))
        XCTAssertTrue(azw3.readingOrder.contains(where: {
            $0.content.contains("bookkit://asset/kindle-image-")
        }))
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
        XCTAssertTrue(
            book.readingOrder.contains(where: { $0.content.contains("data-bookkit-publication") }),
            "Expected linked publication stylesheets to be retained for rendering"
        )
    }

    func testEpubCorpusParsesNavigationHierarchyAndLandmarks() async throws {
        let entry = try XCTUnwrap(
            CorpusManifest.load().first(where: { $0.format == .epub }),
            "Expected at least one EPUB corpus entry"
        )
        let book = try await Book.open(from: entry.fileURL, options: OpenOptions(allowsNetwork: false))

        let enchiridion = try XCTUnwrap(
            book.tableOfContents.first(where: { $0.title == "The Enchiridion" })
        )
        XCTAssertEqual(enchiridion.href, "text/the-enchiridion.xhtml")
        XCTAssertGreaterThan(enchiridion.children.count, 50)
        XCTAssertGreaterThan(book.tableOfContents.flatMap(\.flattened).count, 200)

        XCTAssertTrue(
            book.landmarks.contains(where: {
                $0.title == "Short Works" && $0.roles.contains("bodymatter")
            })
        )
        XCTAssertTrue(
            book.landmarks.contains(where: {
                $0.title == "Endnotes" && $0.roles.contains("footnotes")
            })
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
        XCTAssertEqual(book.id, "a75a6f71-f140-11e3-871d-0025905a0812")
        XCTAssertEqual(book.metadata.language, "ru")
        XCTAssertEqual(book.assets.count, 2)
        XCTAssertNotNil(book.assets.first(where: { $0.id == "cover.jpg" })?.data)
        XCTAssertTrue(
            book.readingOrder.contains(where: {
                $0.content.contains("bookkit://asset/body.jpg")
                    && $0.content.contains("fb2-poem")
            })
        )
        XCTAssertTrue(book.tableOfContents.contains(where: { !$0.children.isEmpty }))
        XCTAssertTrue(book.landmarks.contains(where: { $0.roles.contains("footnotes") }))
    }
}
