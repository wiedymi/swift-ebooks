import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

struct PDFParser: BookParser {
    public let formats: Set<BookFormat> = [.pdf]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try source.loadData(options: options)

        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw BookError.invalidContainer("Unable to open PDF document")
        }
        guard !document.isEncrypted else {
            throw BookError.protectedContent(
                ContentProtection(kind: .pdfEncryption, scheme: "PDF standard security handler")
            )
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
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .normalizedWhitespace().nonEmpty
        let pageList = chapters.map { TOCNode(title: $0.title ?? $0.id, href: $0.href) }
        let outline = document.outlineRoot.map {
            outlineNodes(parent: $0, document: document, path: [])
        } ?? []

        return Book(
            id: DeterministicIdentifier.make(namespace: "pdf", data: data),
            format: .pdf,
            version: "1.x",
            metadata: Metadata(title: title, authors: author.map { [$0] } ?? []),
            readingOrder: chapters,
            assets: [
                Asset(
                    id: "pdf-document",
                    href: source.fileName ?? "document.pdf",
                    mediaType: "application/pdf",
                    data: data
                ),
            ],
            tableOfContents: outline.isEmpty ? pageList : outline,
            landmarks: [],
            pageList: pageList,
            rawExtensions: [:],
            diagnostics: [],
            presentation: BookPresentation(layout: .fixed, spread: .none)
        )
        #else
        // Fallback for toolchains without PDFKit.
        guard data.starts(with: Data("%PDF-".utf8)) else {
            throw BookError.invalidContainer("Not a PDF file")
        }
        guard !PDFProtectionProbe.containsEncryptionDictionary(data) else {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .pdfEncryption,
                    scheme: "PDF encryption dictionary"
                )
            )
        }

        let text = data.bestEffortString().normalizedWhitespace()
        let chapter = Chapter(id: "page-1", href: "pdf://page/1", title: "Page 1", content: text.isEmpty ? "Page 1" : text)
        return Book(
            id: DeterministicIdentifier.make(namespace: "pdf", data: data),
            format: .pdf,
            version: "1.x",
            metadata: Metadata(title: source.fileName ?? "Untitled", authors: []),
            readingOrder: [chapter],
            assets: [],
            tableOfContents: [TOCNode(title: chapter.title ?? chapter.id, href: chapter.href)],
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: [BookDiagnostic(severity: .warning, code: "pdf.fallback-parser", message: "PDFKit unavailable; using fallback parser")],
            presentation: BookPresentation(layout: .fixed, spread: .none)
        )
        #endif
    }

    #if canImport(PDFKit)
    private func outlineNodes(
        parent: PDFOutline,
        document: PDFDocument,
        path: [Int]
    ) -> [TOCNode] {
        (0..<parent.numberOfChildren).compactMap { index in
            guard let item = parent.child(at: index) else { return nil }
            let itemPath = path + [index]
            let children = outlineNodes(parent: item, document: document, path: itemPath)
            let destination = item.destination
                ?? (item.action as? PDFActionGoTo)?.destination
            let pageIndex = destination?.page.map(document.index(for:))
            let href = pageIndex.map { "pdf://page/\($0 + 1)" }
                ?? children.first?.href
                ?? "pdf://page/1"
            return TOCNode(
                id: "pdf-outline-" + itemPath.map(String.init).joined(separator: "."),
                title: item.label?.normalizedWhitespace().nonEmpty ?? "Untitled",
                href: href,
                children: children
            )
        }
    }
    #endif
}

enum PDFProtectionProbe {
    static func containsEncryptionDictionary(_ data: Data) -> Bool {
        let marker = Data("/Encrypt".utf8)
        var searchStart = data.startIndex
        while searchStart <= data.endIndex - marker.count,
              let range = data.range(
                  of: marker,
                  options: [],
                  in: searchStart..<data.endIndex
              )
        {
            let next = range.upperBound
            if next == data.endIndex || isPDFDelimiter(data[next]) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isPDFDelimiter(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 ||
            byte == 32 || [UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"),
                           UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
                           UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"),
                           UInt8(ascii: "%")].contains(byte)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
