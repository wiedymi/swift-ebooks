import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFParser: BookParser {
    public let formats: Set<BookFormat> = [.pdf]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try source.loadData(options: options)

        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw BookError.invalidContainer("Unable to open PDF document")
        }

        var chapters: [Chapter] = []
        for pageIndex in 0..<document.pageCount {
            let page = document.page(at: pageIndex)
            let text = page?.string?.normalizedWhitespace() ?? ""
            chapters.append(
                Chapter(
                    id: "page-\(pageIndex + 1)",
                    href: "pdf://page/\(pageIndex + 1)",
                    title: "Page \(pageIndex + 1)",
                    content: text.isEmpty ? "Page \(pageIndex + 1)" : text
                )
            )
        }

        if chapters.isEmpty {
            throw BookError.malformedDocument("PDF has no pages")
        }

        let attrs = document.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.normalizedWhitespace()
            ?? source.fileName
            ?? "Untitled"

        return Book(
            id: UUID().uuidString,
            format: .pdf,
            version: "1.x",
            metadata: Metadata(title: title, authors: []),
            readingOrder: chapters,
            assets: [],
            tableOfContents: chapters.map { TOCNode(title: $0.title ?? $0.id, href: $0.href) },
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
        #else
        // Fallback for toolchains without PDFKit.
        guard data.starts(with: Data("%PDF-".utf8)) else {
            throw BookError.invalidContainer("Not a PDF file")
        }

        let text = data.bestEffortString().normalizedWhitespace()
        let chapter = Chapter(id: "page-1", href: "pdf://page/1", title: "Page 1", content: text.isEmpty ? "Page 1" : text)
        return Book(
            id: UUID().uuidString,
            format: .pdf,
            version: "1.x",
            metadata: Metadata(title: source.fileName ?? "Untitled", authors: []),
            readingOrder: [chapter],
            assets: [],
            tableOfContents: [TOCNode(title: chapter.title ?? chapter.id, href: chapter.href)],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [BookDiagnostic(severity: .warning, code: "pdf.fallback-parser", message: "PDFKit unavailable; using fallback parser")]
        )
        #endif
    }
}
