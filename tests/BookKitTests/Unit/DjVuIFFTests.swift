import XCTest
@testable import BookKit

final class DjVuIFFTests: XCTestCase {
    func testAllowsTopLevelFormToOmitTerminalPadding() throws {
        let data = Data(
            base64Encoded: "QVQmVEZPUk0AAAArREpWVUlORk8AAAAKAAgACBgAZAAWAUJHNDQAAAANAGSBAgAIAAgA///i+w=="
        )!
        let document = try DjVuIFFParser.parse(data, options: OpenOptions())
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.pages[0].chunks.last?.id, "BG44")
    }

    func testParsesSinglePageContainerAndInfo() throws {
        let data = DjVuTestSupport.document(
            form: DjVuTestSupport.jpegPage(width: 2202, height: 967)
        )

        let document = try DjVuIFFParser.parse(data, options: OpenOptions())

        XCTAssertEqual(document.formType, "DJVU")
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.pages[0].info.width, 2202)
        XCTAssertEqual(document.pages[0].info.height, 967)
        XCTAssertEqual(document.pages[0].info.dpi, 300)
        XCTAssertEqual(document.pages[0].info.gamma, 2.2, accuracy: 0.001)
        XCTAssertEqual(document.pages[0].info.rotation, .upright)
        XCTAssertEqual(document.pages[0].chunks.map(\.id), ["INFO", "BGjp"])
    }

    func testDiscoversPagesInBundledMultipageContainer() throws {
        var directory = Data([0x81, 0, 2])
        directory.append(Data(repeating: 0, count: 8))
        let form = DjVuTestSupport.form("DJVM", [
            DjVuTestSupport.chunk("DIRM", directory),
            DjVuTestSupport.jpegPage(width: 100, height: 200),
            DjVuTestSupport.jpegPage(width: 300, height: 400),
        ])

        let document = try DjVuIFFParser.parse(
            DjVuTestSupport.document(form: form),
            options: OpenOptions()
        )

        XCTAssertEqual(document.formType, "DJVM")
        XCTAssertEqual(document.pages.map(\.info.width), [100, 300])
        XCTAssertEqual(document.pages.map(\.info.height), [200, 400])
    }

    func testRejectsPageWhoseFirstChunkIsNotInfo() throws {
        let form = DjVuTestSupport.form("DJVU", [
            DjVuTestSupport.chunk("BGjp", DjVuTestSupport.onePixelJPEG),
            DjVuTestSupport.info(),
        ])

        XCTAssertThrowsError(
            try DjVuIFFParser.parse(
                DjVuTestSupport.document(form: form),
                options: OpenOptions()
            )
        ) { error in
            guard case BookError.malformedDocument(let message) = error else {
                return XCTFail("Expected malformedDocument, got \(error)")
            }
            XCTAssertTrue(message.contains("INFO"))
        }
    }

    func testRejectsChunkLengthOutsideContainer() throws {
        var data = Data("AT&TFORM".utf8)
        data.append(contentsOf: [0, 0, 0, 20])
        data.append(Data("DJVUINFO".utf8))
        data.append(contentsOf: [0xff, 0xff, 0xff, 0xff])

        XCTAssertThrowsError(try DjVuIFFParser.parse(data, options: OpenOptions())) { error in
            guard case BookError.invalidContainer = error else {
                return XCTFail("Expected invalidContainer, got \(error)")
            }
        }
    }

    func testEnforcesConfiguredChunkCountLimit() throws {
        let form = DjVuTestSupport.form("DJVU", [
            DjVuTestSupport.info(),
            DjVuTestSupport.chunk("BGjp", DjVuTestSupport.onePixelJPEG),
        ])
        let options = OpenOptions(maxArchiveEntries: 2)

        XCTAssertThrowsError(
            try DjVuIFFParser.parse(DjVuTestSupport.document(form: form), options: options)
        )
    }
}
