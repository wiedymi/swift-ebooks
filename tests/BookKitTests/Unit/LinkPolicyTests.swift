import XCTest
@testable import BookKit

final class LinkPolicyTests: XCTestCase {
    func testDefaultLinkPolicy() async throws {
        let policy = DefaultLinkPolicy()

        let internalAction = await policy.action(
            for: URL(string: "#note-1", relativeTo: URL(string: "bookkit://chapter/c1.xhtml")!)!,
            context: LinkContext(currentChapterHref: "c1.xhtml")
        )
        XCTAssertEqual(internalAction, .follow)

        let chapterAction = await policy.action(
            for: URL(string: "c2.xhtml#p4", relativeTo: URL(string: "bookkit://chapter/c1.xhtml")!)!,
            context: LinkContext(currentChapterHref: "c1.xhtml")
        )
        XCTAssertEqual(chapterAction, .follow)

        let externalAction = await policy.action(
            for: URL(string: "https://example.com")!,
            context: LinkContext(currentChapterHref: "c1.xhtml")
        )
        XCTAssertEqual(externalAction, .block)
    }

    func testResolveLinksClassifiesAnchorSpineAndUnsafeSchemes() {
        let anchor = URL(string: "#note-1", relativeTo: URL(string: "bookkit://chapter/current")!)!
        XCTAssertEqual(ResolveLinks.classify(anchor), .anchor)

        let spine = URL(string: "Text/ch2.xhtml#p4", relativeTo: URL(string: "bookkit://chapter/current")!)!
        XCTAssertEqual(ResolveLinks.classify(spine), .spine)

        let external = URL(string: "https://example.com")!
        XCTAssertEqual(ResolveLinks.classify(external), .external)

        let unsupported = URL(string: "javascript:alert(1)")!
        XCTAssertEqual(ResolveLinks.classify(unsupported), .unsupported)
    }
}
