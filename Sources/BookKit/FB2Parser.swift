import Foundation

public struct FB2Parser: BookParser {
    public let formats: Set<BookFormat> = [.fb2]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try source.loadData(options: options)
        let xml = data.bestEffortString()

        let title = xml.firstMatch(for: "<book-title[^>]*>(.*?)</book-title>") ?? "Untitled"

        var authors: [String] = []
        let authorBlocks = xml.allMatches(for: "<author[^>]*>(.*?)</author>")
        for block in authorBlocks {
            let first = block.firstMatch(for: "<first-name[^>]*>(.*?)</first-name>")
            let last = block.firstMatch(for: "<last-name[^>]*>(.*?)</last-name>")
            let full = [first, last].compactMap { $0 }.joined(separator: " ").normalizedWhitespace()
            if !full.isEmpty {
                authors.append(full)
            }
        }

        var chapters: [Chapter] = []
        let sectionBlocks = xml.allMatches(for: "<section[^>]*>(.*?)</section>")
        var chapterIndex = 0
        for section in sectionBlocks {
            let sectionTitle = section.firstMatch(for: "<title[^>]*>(.*?)</title>")
            let body = section.strippingHTML().normalizedWhitespace()
            if body.isEmpty {
                continue
            }
            chapterIndex += 1
            chapters.append(
                Chapter(
                    id: "section-\(chapterIndex)",
                    href: "#section-\(chapterIndex)",
                    title: sectionTitle,
                    content: body
                )
            )
        }

        if chapters.isEmpty {
            let body = xml.strippingHTML().normalizedWhitespace()
            if body.isEmpty {
                throw BookError.malformedDocument("FB2 content is empty")
            }
            chapters.append(Chapter(id: "body-1", href: "#body-1", title: title, content: body))
        }

        let toc = chapters.map { TOCNode(title: $0.title ?? $0.id, href: $0.href) }

        return Book(
            id: UUID().uuidString,
            format: .fb2,
            version: "2.0",
            metadata: Metadata(title: title, authors: authors),
            readingOrder: chapters,
            assets: [],
            tableOfContents: toc,
            landmarks: [],
            pageList: [],
            rawExtensions: [:],
            diagnostics: []
        )
    }
}
