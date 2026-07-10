#if canImport(SwiftUI)
import SwiftUI
import XCTest
@testable import BookKit

final class FixedPageBookViewTests: XCTestCase {
    func testOverlayContextMapsAndClipsSourceCoordinates() {
        let context = makeContext()

        XCTAssertEqual(
            context.frame(for: PageRectangle(x: 100, y: 200, width: 300, height: 400)),
            CGRect(x: 70, y: 140, width: 60, height: 80)
        )
        XCTAssertEqual(
            context.frame(for: PageRectangle(x: -100, y: -100, width: 200, height: 200)),
            CGRect(x: 50, y: 100, width: 20, height: 20)
        )
    }

    func testHorizontalLineGetsMinimumAccessibleHitTarget() {
        let context = makeContext()
        let frame = context.hitFrame(
            for: PageRectangle(x: 100, y: 200, width: 300, height: 0),
            minimumSize: 28
        )

        XCTAssertEqual(frame, CGRect(x: 70, y: 126, width: 60, height: 28))
    }

    private func makeContext() -> FixedPageOverlayContext {
        FixedPageOverlayContext(
            pageIndex: 0,
            chapter: Chapter(id: "page", href: "page-1", title: "Page", content: ""),
            presentation: PagePresentation(pixelWidth: 1000, pixelHeight: 2000),
            locator: .start,
            sourceSize: CGSize(width: 1000, height: 2000),
            imageFrame: CGRect(x: 50, y: 100, width: 200, height: 400)
        )
    }
}
#endif
