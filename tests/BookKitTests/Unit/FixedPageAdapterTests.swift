import XCTest
@testable import BookKit

final class FixedPageAdapterTests: XCTestCase {
    func testMapsPagesAssetsAndLTRSpreads() {
        let book = makeBook(progression: .leftToRight)
        let adapter = FixedPageAdapter(book: book)

        XCTAssertEqual(adapter.pageCount, 4)
        XCTAssertEqual(adapter.position(forPageIndex: 99).spineIndex, 3)
        XCTAssertEqual(adapter.pageIndex(for: Position(spineIndex: -5, progression: 0)), 0)
        XCTAssertEqual(adapter.asset(forPageIndex: 2)?.id, "asset-2")
        XCTAssertEqual(adapter.spreads().map(\.pageIndices), [[0], [1, 2], [3]])
    }

    func testRTLSpreadVisualOrderIsReversed() {
        let adapter = FixedPageAdapter(book: makeBook(progression: .rightToLeft))
        XCTAssertEqual(adapter.spreads().map(\.pageIndices), [[0], [2, 1], [3]])
    }

    @MainActor
    func testContentRendererDoesNotRequireWebBridgeForImageBook() async throws {
        let book = makeBook(progression: .leftToRight)
        let renderer = try ContentRenderer(book: book)

        XCTAssertEqual(renderer.mode, .fixed)
        XCTAssertEqual(renderer.pageCount(), 4)
        try await renderer.renderChapter(at: 2, viewport: Viewport(width: 800, height: 600))
        let renderedPosition = await renderer.currentPosition()
        XCTAssertEqual(renderedPosition.spineIndex, 2)
        try await renderer.nextPage()
        let nextPosition = await renderer.currentPosition()
        XCTAssertEqual(nextPosition.spineIndex, 3)
    }

    private func makeBook(progression: ReadingProgression) -> Book {
        let chapters = (0..<4).map { index in
            Chapter(
                id: "page-\(index)",
                href: "\(index).jpg",
                title: "Page \(index + 1)",
                content: "",
                resourceID: "asset-\(index)",
                mediaType: "image/jpeg",
                page: PagePresentation(
                    side: index == 0 || index == 3 ? .center : (index == 1 ? .left : .right),
                    isCover: index == 0,
                    isSpread: index == 3
                )
            )
        }
        return Book(
            id: "fixed",
            format: .cbz,
            version: "1",
            metadata: Metadata(title: "Fixed", authors: []),
            readingOrder: chapters,
            assets: (0..<4).map {
                Asset(id: "asset-\($0)", href: "\($0).jpg", mediaType: "image/jpeg", data: Data([$0]))
            },
            tableOfContents: [],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(
                layout: .fixed,
                readingProgression: progression,
                coverPageIndex: 0
            )
        )
    }
}
