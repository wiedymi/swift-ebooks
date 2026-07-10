import XCTest
@testable import BookKit

final class FixedLayoutEPUBTests: XCTestCase {
    func testImageOnlyEPUBUsesFixedPagePresentation() async throws {
        let container = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:image-book</dc:identifier>
            <dc:title>Image Book</dc:title>
            <meta property="rendition:layout">pre-paginated</meta>
          </metadata>
          <manifest>
            <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="page2" href="images/002.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine page-progression-direction="rtl">
            <itemref idref="cover" properties="page-spread-center"/>
            <itemref idref="page2" properties="page-spread-right"/>
          </spine>
        </package>
        """
        let epub = try ArchiveTestSupport.makeZIP([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("EPUB/package.opf", Data(opf.utf8)),
            ("EPUB/images/cover.jpg", Data([0xff, 0xd8, 1])),
            ("EPUB/images/002.jpg", Data([0xff, 0xd8, 2])),
        ])

        let book = try await EPUBParser().parse(
            source: .data(epub, fileName: "image.epub"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.presentation.layout, .fixed)
        XCTAssertEqual(book.presentation.readingProgression, .rightToLeft)
        XCTAssertEqual(book.presentation.coverPageIndex, 0)
        XCTAssertEqual(book.readingOrder.map(\.resourceID), ["cover", "page2"])
        XCTAssertEqual(book.readingOrder[0].page?.side, .center)
        XCTAssertEqual(book.readingOrder[1].page?.side, .right)
        XCTAssertEqual(book.assets.map(\.id), ["cover", "page2"])
    }
}
