#if canImport(PDFKit) && !os(tvOS)
    import CoreGraphics
    import CoreText
    import PDFKit
    import XCTest
    @testable import BookKit

    @MainActor
    final class PDFTextTests: XCTestCase {
        func testSearchLocationsResolveInNativePDFAndMarksPreserveExistingAnnotations() async throws {
            let data = try textPDF()
            let book = try await Book.open(source: .data(data, fileName: "text.pdf"))
            let results = try await book.search("needle")
            XCTAssertEqual(results.count, 2)
            let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
            view.document = try XCTUnwrap(PDFDocument(data: data))
            let support = PDFTextSupport(view: view)
            let page = try XCTUnwrap(view.document?.page(at: 0))
            let publisherMark = PDFAnnotation(
                bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .square, withProperties: nil)
            page.addAnnotation(publisherMark)
            let decorations = results.enumerated().map { index, result in
                Decoration(
                    id: "result-\(index)", group: .search, locator: book.locator(for: result.position),
                    style: .default(for: .search))
            }
            support.apply(decorations)
            XCTAssertGreaterThan(page.annotations.count, 1)
            XCTAssertEqual(support.tapped(id: "result-0", group: .search)?.locator, decorations[0].locator)
            try support.navigate(to: decorations[1].locator)
            XCTAssertTrue(view.currentPage === view.document?.page(at: 1))
            support.apply([])
            XCTAssertEqual(page.annotations.count, 1)
            XCTAssertTrue(page.annotations[0] === publisherMark)
            XCTAssertTrue(view.document?.page(at: 1)?.annotations.isEmpty == true)
        }

        func testMultiPageSelectionCreatesPortableMarks() async throws {
            let data = try textPDF()
            let book = try await Book.open(source: .data(data, fileName: "text.pdf"))
            let reader = try await BookReader(book: book)
            let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
            let document = try XCTUnwrap(PDFDocument(data: data))
            view.document = document
            let selection = PDFSelection(document: document)
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                let text = try XCTUnwrap(page.string) as NSString
                selection.add(try XCTUnwrap(page.selection(for: NSRange(location: 0, length: text.length))))
            }
            view.setCurrentSelection(selection, animate: false)
            let parts = PDFTextSupport(view: view).selections()
            XCTAssertEqual(parts.count, 2)
            reader.updatePDFSelection(parts)
            XCTAssertEqual(reader.selection?.locators.count, 2)
            let marks = try await reader.highlightSelection(id: "note")
            XCTAssertEqual(marks.map(\.id), ["note", "note-1"])
            XCTAssertEqual(marks.map(\.locator.sectionIndex), [0, 1])
            let decoded = try JSONDecoder().decode([Decoration].self, from: JSONEncoder().encode(marks))
            XCTAssertEqual(decoded, marks)
            await reader.shutdown()
        }

        func testNativeWhitespaceOffsetsAndAmbiguousQuotes() throws {
            let map = NormalizedText("😀 First\n\nneedle. Second\tneedle.")
            let target = try XCTUnwrap(map.location(forOriginalRange: NSRange(location: 10, length: 6)))
            XCTAssertEqual(target.quote, "needle")
            XCTAssertEqual(map.originalRange(for: target), NSRange(location: 10, length: 6))
            XCTAssertNil(map.originalRange(for: ReaderTextRange(start: 99, end: 105, quote: "needle")))
            XCTAssertNil(map.location(forOriginalRange: NSRange(location: Int.max, length: 1)))
        }

        func testImageOnlyPDFDoesNotSpeakPageLabels() async throws {
            let data = NSMutableData()
            var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
            context.beginPDFPage(nil)
            context.fill(bounds)
            context.endPDFPage()
            context.closePDF()
            let book = try await Book.open(source: .data(data as Data, fileName: "image.pdf"))
            let text = try await book.text(inSection: 0)
            XCTAssertTrue(text.isEmpty)
        }

        private func textPDF() throws -> Data {
            let data = NSMutableData()
            var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
            for text in ["First page has a needle.", "Second page has a needle."] {
                context.beginPDFPage(nil)
                let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
                let string = NSAttributedString(
                    string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: 30, y: 500)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }
    }
#endif
