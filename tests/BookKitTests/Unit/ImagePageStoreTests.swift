import XCTest
@testable import BookKit

final class ImagePageStoreTests: XCTestCase {
    func testCreatesAndPrefetchesThumbnailsFromRealPNGData() async throws {
        let png = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        let book = makeBook(pageData: [png, png, png, png])
        let store = ImagePageStore(book: book)

        let pageCount = await store.pageCount
        let firstPage = try await store.data(forPageIndex: 0)
        XCTAssertEqual(pageCount, 4)
        XCTAssertEqual(firstPage, png)
        let thumbnail = try await store.thumbnail(forPageIndex: 0, maxPixelSize: 64)
        XCTAssertTrue(thumbnail.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))

        await store.prefetch(aroundPageIndex: 1, distance: 2, thumbnailPixelSize: 64)
        let prefetchedCount = await store.cachedThumbnailCount()
        XCTAssertEqual(prefetchedCount, 4)

        await store.removeAllThumbnails()
        let clearedCount = await store.cachedThumbnailCount()
        XCTAssertEqual(clearedCount, 0)
    }

    func testMissingPageDataThrowsTypedError() async throws {
        let store = ImagePageStore(book: makeBook(pageData: [nil]))
        do {
            _ = try await store.data(forPageIndex: 0)
            XCTFail("Expected missingAsset")
        } catch BookError.missingAsset(_) {
            // Expected.
        }
    }

    func testPrefetchIgnoresInvalidIndicesWithoutOverflow() async throws {
        for count in [0, 1, 4] {
            let store = ImagePageStore(book: makeBook(pageData: Array(repeating: nil, count: count)))
            for index in [Int.min, -10, -1, count, count + 10, Int.max] {
                await store.prefetch(aroundPageIndex: index, distance: Int.max)
            }
            let cached = await store.cachedThumbnailCount()
            XCTAssertEqual(cached, 0)
        }
        let store = ImagePageStore(book: makeBook(pageData: []))
        do {
            _ = try await store.data(forPageIndex: Int.max)
            XCTFail("Expected missing asset")
        } catch BookError.missingAsset { }
    }

    private func makeBook(pageData: [Data?]) -> Book {
        Book(
            id: "images",
            format: .cbz,
            version: "1",
            metadata: Metadata(title: "Images", authors: []),
            readingOrder: pageData.indices.map { index in
                Chapter(
                    id: "page-\(index)",
                    href: "\(index).png",
                    title: "Page \(index + 1)",
                    content: "",
                    resourceID: "asset-\(index)",
                    mediaType: "image/png",
                    page: PagePresentation(isCover: index == 0)
                )
            },
            assets: pageData.indices.map { index in
                Asset(
                    id: "asset-\(index)",
                    href: "\(index).png",
                    mediaType: "image/png",
                    data: pageData[index]
                )
            },
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .fixed, coverPageIndex: 0)
        )
    }
}
