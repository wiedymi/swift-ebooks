import XCTest
@testable import BookKit

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

final class DjVuParserTests: XCTestCase {
    func testRejectsSecureDjVuAsProtectedContent() async throws {
        do {
            _ = try await DjVuParser().parse(
                source: .data(Data("SDJV\0\0\0\0".utf8), fileName: "protected.djvu"),
                options: OpenOptions()
            )
            XCTFail("Expected protected content")
        } catch BookError.protectedContent(let protection) {
            XCTAssertEqual(protection.kind, .djvuEncryption)
            XCTAssertEqual(protection.scheme, "Secure DjVu")
        }
    }

    func testParsesJPEGPageTextAndLinkAnnotation() async throws {
        let annotation = """
        (background #FFFFFF)
        (maparea "https://example.com/details" "Details" (rect 100 200 300 400) (border #000000))
        """
        let source = DjVuTestSupport.document(
            form: DjVuTestSupport.jpegPage(
                width: 1200,
                height: 1800,
                text: "Chapter one\nReadable OCR text",
                annotation: annotation
            )
        )

        let book = try await DjVuParser().parse(
            source: .data(source, fileName: "Clean Room.djvu"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.format, .djvu)
        XCTAssertEqual(book.metadata.title, "Clean Room")
        XCTAssertEqual(book.presentation.layout, .fixed)
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertEqual(book.readingOrder[0].content, "Chapter one\nReadable OCR text")
        XCTAssertEqual(book.readingOrder[0].mediaType, "image/jpeg")
        XCTAssertEqual(book.readingOrder[0].page?.pixelWidth, 1200)
        XCTAssertEqual(book.readingOrder[0].page?.pixelHeight, 1800)
        XCTAssertEqual(book.readingOrder[0].page?.links.count, 1)
        XCTAssertEqual(book.readingOrder[0].page?.links[0].href, "https://example.com/details")
        XCTAssertEqual(book.readingOrder[0].page?.links[0].title, "Details")
        XCTAssertEqual(book.readingOrder[0].page?.links[0].bounds, PageRectangle(x: 100, y: 1200, width: 300, height: 400))
        XCTAssertEqual(book.assets.single?.data, DjVuTestSupport.onePixelJPEG)
    }

    func testNormalizesAnnotationShapesAndRelativePageTargets() {
        let annotations = """
        (maparea "#+1" "Polygon" (poly 10 20 40 20 30 60))
        (maparea "#-1" "Line" (line 100 200 140 240))
        """
        let links = DjVuAnnotations.links(from: annotations, pageHeight: 500) {
            DjVuNavigationTarget.resolve(
                $0,
                directory: nil,
                currentPageIndex: 1,
                pageCount: 3
            )
        }

        XCTAssertEqual(links.map(\.href), ["page-3", "page-1"])
        XCTAssertEqual(
            links[0].bounds,
            PageRectangle(x: 10, y: 440, width: 30, height: 40)
        )
        XCTAssertEqual(
            links[1].bounds,
            PageRectangle(x: 100, y: 260, width: 40, height: 40)
        )
        XCTAssertEqual(
            DjVuNavigationTarget.resolve(
                "#+1",
                directory: nil,
                currentPageIndex: 2,
                pageCount: 3
            ),
            "#+1"
        )
    }

    func testFallsBackToPageListForBundledDocumentWithoutDecodedDirectory() async throws {
        var directory = Data([0x81, 0, 2])
        directory.append(Data(repeating: 0, count: 8))
        let data = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVM", [
                DjVuTestSupport.chunk("DIRM", directory),
                DjVuTestSupport.jpegPage(text: "First"),
                DjVuTestSupport.jpegPage(text: "Second"),
            ])
        )

        let book = try await DjVuParser().parse(
            source: .data(data, fileName: "Two Pages.djvu"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.readingOrder.map(\.title), ["Page 1", "Page 2"])
        XCTAssertEqual(book.pageList.map(\.href), ["page-1", "page-2"])
        XCTAssertEqual(book.diagnostics.first?.code, "djvu.directory-unavailable")
    }

    func testParsesCompressedDirectoryOutlineTextAndAnnotations() async throws {
        let directory = Data(
            base64Encoded: "///Uv4of/VhHVCcf+SwuDpmchhz8al9ytQVYgCh4sSD5Uftuhnx66P6i7w=="
        )!
        let navigation = Data(
            base64Encoded: "//++/xXmuRzWH3GHlhhvlGBnSNvSGJF2ulvO8SedwYlBILmVGBKLJ/SlQP+gR6gZFn8="
        )!
        let text = Data(base64Encoded: "///n3/30p/iitpXch8c2D7okX4HaWWoHWuU=")!
        let annotations = Data(
            base64Encoded: "///N/rXo2gDh+smUIOW/tyNsyKRCC8zbvs4hL5QFeLvys/imn3iwQbFioT58/1oKnw=="
        )!
        var directoryPayload = Data([0x81, 0, 2])
        directoryPayload.append(Data(repeating: 0, count: 8))
        directoryPayload.append(directory)
        let firstPage = DjVuTestSupport.form("DJVU", [
            DjVuTestSupport.info(),
            DjVuTestSupport.chunk("BGjp", DjVuTestSupport.onePixelJPEG),
            DjVuTestSupport.chunk("TXTz", text),
            DjVuTestSupport.chunk("ANTz", annotations),
        ])
        let secondPage = DjVuTestSupport.jpegPage()
        let data = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVM", [
                DjVuTestSupport.chunk("DIRM", directoryPayload),
                DjVuTestSupport.chunk("NAVM", navigation),
                firstPage,
                secondPage,
            ])
        )

        let book = try await DjVuParser().parse(
            source: .data(data, fileName: "Compressed.djvu"),
            options: OpenOptions()
        )

        XCTAssertEqual(book.readingOrder.map(\.title), ["Chapter One", "Page 2"])
        XCTAssertEqual(book.readingOrder[0].content, "Compressed OCR text")
        XCTAssertEqual(book.readingOrder[0].page?.links.first?.href, "page-2")
        XCTAssertEqual(book.tableOfContents.count, 1)
        XCTAssertEqual(book.tableOfContents[0].title, "Contents")
        XCTAssertEqual(book.tableOfContents[0].children.map(\.title), ["First", "Second"])
        XCTAssertEqual(book.tableOfContents[0].children.map(\.href), ["page-1", "page-2"])
        XCTAssertTrue(book.diagnostics.isEmpty)
    }

    func testParsesIW44Page() async throws {
        let data = Data(
            base64Encoded: "QVQmVEZPUk0AAAA+REpWVUlORk8AAAAKAAgACBgAZAAWAUJHNDQAAAAgAGSBAgAIAAgA8u+h00+3HAekvu+HFp0aCa8nz17tBt8="
        )!
        let book = try await DjVuParser().parse(
            source: .data(data, fileName: "wavelet.djvu"),
            options: OpenOptions()
        )
        XCTAssertEqual(book.assets.single?.mediaType, "image/png")
        XCTAssertEqual(book.readingOrder.single?.page?.pixelWidth, 8)
        XCTAssertEqual(book.readingOrder.single?.page?.pixelHeight, 8)
    }

    func testComposesIW44JB2AndForegroundPalette() async throws {
        let background = Data([
            0x00, 0x64, 0x81, 0x02, 0x00, 0x08, 0x00, 0x08, 0x00,
            0xff, 0xff, 0xe2, 0xfb,
        ])
        let mask = Data([0x8e, 0xe9, 0x81, 0x91, 0xd5])
        let palette = Data([
            0x80, 0x00, 0x01, 0x00, 0x00, 0xff,
            0x00, 0x00, 0x01,
            0xff, 0xff, 0xfc, 0x84, 0x9d, 0xbf,
        ])
        let source = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVU", [
                DjVuTestSupport.info(width: 8, height: 8),
                DjVuTestSupport.chunk("Sjbz", mask),
                DjVuTestSupport.chunk("FGbz", palette),
                DjVuTestSupport.chunk("BG44", background),
            ])
        )

        let book = try await DjVuParser().parse(
            source: .data(source, fileName: "compound.djvu"),
            options: OpenOptions()
        )
        let pixels = try rgbaPixels(book.assets[0].data!)
        XCTAssertEqual(Array(pixels[0..<3]), [128, 128, 128])
        let foreground = (3 * 8 + 3) * 4
        XCTAssertEqual(Array(pixels[foreground..<(foreground + 3)]), [255, 0, 0])
    }

    func testDecodesSmmrFaxG4Mask() async throws {
        let smmr = Data([
            0x4d, 0x4d, 0x52, 0x01, 0x00, 0x08, 0x00, 0x08,
            0x26, 0xa2, 0xfc, 0xc3, 0xe3, 0xfc, 0x00, 0x40, 0x04,
        ])
        let source = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVU", [
                DjVuTestSupport.info(width: 8, height: 8),
                DjVuTestSupport.chunk("Smmr", smmr),
            ])
        )
        let book = try await DjVuParser().parse(
            source: .data(source, fileName: "fax.djvu"),
            options: OpenOptions()
        )
        let pixels = try rgbaPixels(book.assets[0].data!)
        XCTAssertEqual(Array(pixels[0..<3]), [255, 255, 255])
        let foreground = (3 * 8 + 3) * 4
        XCTAssertEqual(Array(pixels[foreground..<(foreground + 3)]), [0, 0, 0])
    }

    func testDecodesStripedSmmrFaxG4Mask() async throws {
        let smmr = Data([
            0x4d, 0x4d, 0x52, 0x03, 0x00, 0x08, 0x00, 0x08,
            0x00, 0x04,
            0x00, 0x00, 0x00, 0x08,
            0x26, 0xa2, 0xfc, 0xc3, 0xc0, 0x04, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x06,
            0x26, 0xa2, 0xfe, 0x00, 0x20, 0x02,
        ])
        let source = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVU", [
                DjVuTestSupport.info(width: 8, height: 8),
                DjVuTestSupport.chunk("Smmr", smmr),
            ])
        )
        let book = try await DjVuParser().parse(
            source: .data(source, fileName: "striped-fax.djvu"),
            options: OpenOptions()
        )
        let pixels = try rgbaPixels(book.assets[0].data!)
        XCTAssertEqual(Array(pixels[0..<3]), [255, 255, 255])
        let foreground = (3 * 8 + 3) * 4
        XCTAssertEqual(Array(pixels[foreground..<(foreground + 3)]), [0, 0, 0])
    }

    func testResolvesIncludedSharedJB2Dictionary() async throws {
        let compressedDirectory = Data([
            0xff, 0xff, 0xe3, 0xbf, 0x8a, 0x1f, 0xec, 0x7c,
            0x67, 0x42, 0x87, 0x6c, 0xfc, 0xd2, 0x21, 0x9b,
            0x4a, 0x99, 0x97, 0xde, 0x3a, 0x8b, 0xca, 0x08,
            0x06, 0xa0, 0x7d, 0xf2, 0x57,
        ])
        var directory = Data([
            0x81, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x58,
        ])
        directory.append(compressedDirectory)
        let dictionary = DjVuTestSupport.form("DJVI", [
            DjVuTestSupport.chunk("Djbz", Data([0xe7, 0x69, 0x4f])),
        ])
        let page = DjVuTestSupport.form("DJVU", [
            DjVuTestSupport.info(width: 4, height: 4),
            DjVuTestSupport.chunk("INCL", Data("dict.iff".utf8)),
            DjVuTestSupport.chunk("Sjbz", Data([0x15, 0x84, 0x04, 0xe3, 0xef])),
        ])
        let source = DjVuTestSupport.document(
            form: DjVuTestSupport.form("DJVM", [
                DjVuTestSupport.chunk("DIRM", directory),
                dictionary,
                page,
            ])
        )
        let book = try await DjVuParser().parse(
            source: .data(source, fileName: "shared.djvu"),
            options: OpenOptions()
        )
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertEqual(book.assets.single?.mediaType, "image/png")
        XCTAssertTrue(book.diagnostics.isEmpty)
    }

    private func rgbaPixels(_ data: Data) throws -> [UInt8] {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BookError.renderingFailed("Unable to decode test PNG")
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw BookError.renderingFailed("Unable to create test raster")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
        #else
        throw XCTSkip("ImageIO is unavailable")
        #endif
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
