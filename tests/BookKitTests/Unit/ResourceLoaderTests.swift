import XCTest
@testable import BookKit

final class ResourceLoaderTests: XCTestCase {
    func testLoadsInMemoryAssetByID() async throws {
        let data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [Asset(id: "img1", href: "img.png", mediaType: "image/png", data: data)],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book)
        let loaded = try await loader.data(forAssetID: "img1")
        XCTAssertEqual(loaded, data)
    }

    func testBlocksRemoteFetchWhenNetworkDisabled() async throws {
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book, options: OpenOptions(allowsNetwork: false))
        await XCTAssertThrowsErrorAsync(try await loader.data(for: URL(string: "https://example.com")!))
    }

    func testSupportsBookKitAssetURL() async throws {
        let payload = Data([10, 20, 30])
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [Asset(id: "asset-a", href: "a.bin", mediaType: "application/octet-stream", data: payload)],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book)
        let data = try await loader.data(for: URL(string: "bookkit://asset/asset-a")!)
        XCTAssertEqual(data, payload)
    }

    func testRejectsMismatchedInMemoryAssetMediaType() async throws {
        let payload = Data("not-a-png".utf8)
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [Asset(id: "img", href: "img.png", mediaType: "image/png", data: payload)],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book)
        await XCTAssertThrowsErrorAsync(try await loader.data(forAssetID: "img"))
    }

    func testRejectsAssetPayloadOverConfiguredSizeLimit() async throws {
        let payload = Data([1, 2, 3, 4])
        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [Asset(id: "bin", href: "bin.dat", mediaType: "application/octet-stream", data: payload)],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book, maxAssetBytes: 2)
        await XCTAssertThrowsErrorAsync(try await loader.data(forAssetID: "bin"))
    }

    func testBlocksFileURLOutsideAllowedRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("outside".utf8).write(to: outside)

        let book = Book(
            id: "id",
            format: .epub,
            version: "1",
            metadata: Metadata(title: "T", authors: []),
            readingOrder: [Chapter(id: "c1", href: "c1", title: nil, content: "x")],
            assets: [],
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )

        let loader = ResourceLoader(book: book, options: OpenOptions(), allowedRoot: root)
        await XCTAssertThrowsErrorAsync(try await loader.data(for: outside))
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            // expected
        }
    }
}
