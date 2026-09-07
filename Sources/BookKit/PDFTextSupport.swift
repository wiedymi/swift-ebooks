import Foundation

#if canImport(PDFKit) && !os(tvOS)
    import PDFKit
    #if canImport(UIKit)
        import UIKit
        private typealias PDFTextColor = UIColor
    #else
        import AppKit
        private typealias PDFTextColor = NSColor
    #endif

    public struct PDFTextSelection: Sendable, Equatable {
        public var pageIndex: Int
        public var range: ReaderTextRange
        /// Bounds in the PDF view's coordinates, in points.
        public var bounds: CGRect

        public init(pageIndex: Int, range: ReaderTextRange, bounds: CGRect) {
            self.pageIndex = pageIndex
            self.range = range
            self.bounds = bounds
        }
    }

    @MainActor
    final class PDFTextSupport {
        private(set) weak var view: PDFView?
        private var marks: [(annotation: PDFAnnotation, decoration: Decoration)] = []
        private var applied: [Decoration] = []
        private weak var document: PDFDocument?

        init(view: PDFView) { self.view = view }

        isolated deinit {
            for mark in marks { mark.annotation.page?.removeAnnotation(mark.annotation) }
        }

        func selections() -> [PDFTextSelection] {
            guard let view, let document = view.document, let selection = view.currentSelection else {
                return []
            }
            return selection.pages.flatMap { page -> [PDFTextSelection] in
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0, pageIndex < document.pageCount else { return [] }
                let text = NormalizedText(page.string ?? "")
                return (0..<selection.numberOfTextRanges(on: page)).compactMap { index in
                    let raw = selection.range(at: index, on: page)
                    guard let range = text.location(forOriginalRange: raw) else { return nil }
                    return PDFTextSelection(
                        pageIndex: pageIndex, range: range,
                        bounds: view.convert(selection.bounds(for: page), from: page))
                }
            }
        }

        func navigate(to locator: Locator) throws {
            guard let view, let document = view.document,
                locator.sectionIndex >= 0, locator.sectionIndex < document.pageCount,
                let page = document.page(at: locator.sectionIndex)
            else { return }
            guard let target = locator.textRange else {
                view.go(to: page)
                return
            }
            guard let range = NormalizedText(page.string ?? "").originalRange(for: target),
                let selection = page.selection(for: range)
            else {
                throw BookError.navigationFailed("The PDF text location could not be found")
            }
            view.go(to: selection)
        }

        func apply(_ decorations: [Decoration]) {
            guard let view, let document = view.document else { return }
            guard applied != decorations || self.document !== document else { return }
            for mark in marks { mark.annotation.page?.removeAnnotation(mark.annotation) }
            marks.removeAll()
            applied = decorations
            self.document = document
            for decoration in decorations {
                guard let target = decoration.locator.textRange,
                    decoration.locator.sectionIndex >= 0,
                    decoration.locator.sectionIndex < document.pageCount,
                    let page = document.page(at: decoration.locator.sectionIndex),
                    let range = NormalizedText(page.string ?? "").originalRange(for: target),
                    let selection = page.selection(for: range)
                else { continue }
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    for (color, type) in [
                        (decoration.style.backgroundColor, PDFAnnotationSubtype.highlight),
                        (decoration.style.underlineColor, PDFAnnotationSubtype.underline),
                    ] {
                        guard let color else { continue }
                        let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                        annotation.color = Self.color(color) ?? .yellow
                        annotation.contents = target.quote
                        annotation.shouldPrint = false
                        annotation.setValue(
                            decoration.id, forAnnotationKey: PDFAnnotationKey(rawValue: "BookKitDecorationID")
                        )
                        annotation.setValue(
                            decoration.group.rawValue,
                            forAnnotationKey: PDFAnnotationKey(rawValue: "BookKitDecorationGroup"))
                        page.addAnnotation(annotation)
                        marks.append((annotation, decoration))
                    }
                }
            }
        }

        func tapped(id: String, group: DecorationGroup) -> DecorationTapEvent? {
            guard let mark = marks.first(where: { $0.decoration.id == id && $0.decoration.group == group })
            else { return nil }
            return DecorationTapEvent(
                id: mark.decoration.id, group: mark.decoration.group, locator: mark.decoration.locator)
        }

        /// Native PDF marks accept #RGB, #RRGGBB, and #RRGGBBAA colors.
        private static func color(_ value: String) -> PDFTextColor? {
            guard value.hasPrefix("#") else { return nil }
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt32(digits, radix: 16) else {
                return nil
            }
            let rgba = digits.count == 6 ? (number << 8) | 255 : number
            return PDFTextColor(
                red: CGFloat((rgba >> 24) & 255) / 255,
                green: CGFloat((rgba >> 16) & 255) / 255,
                blue: CGFloat((rgba >> 8) & 255) / 255,
                alpha: CGFloat(rgba & 255) / 255)
        }
    }
#endif
