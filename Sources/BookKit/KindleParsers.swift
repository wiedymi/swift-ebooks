import Foundation

public struct MOBIParser: BookParser {
    public let formats: Set<BookFormat> = [.mobi]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        try parseKindle(source: source, options: options, format: .mobi)
    }
}

public struct AZW3Parser: BookParser {
    public let formats: Set<BookFormat> = [.azw3]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        try parseKindle(source: source, options: options, format: .azw3)
    }
}

private func parseKindle(source: BookSource, options: OpenOptions, format: BookFormat) throws -> Book {
    let data = try source.loadData(options: options)
    let ascii = data.asciiStrings(minLength: 3)

    guard ascii.contains(where: { $0.contains("BOOKMOBI") }) || source.fileName?.lowercased().hasSuffix(".azw3") == true || source.fileName?.lowercased().hasSuffix(".mobi") == true else {
        throw BookError.invalidContainer("Not a recognized MOBI/AZW3 container")
    }

    let cleaned = ascii
        .map { $0.replacingOccurrences(of: "_", with: " ").normalizedWhitespace() }
        .filter { !$0.isEmpty }

    let title = chooseTitle(from: cleaned) ?? "Untitled"
    let authors = chooseAuthors(from: cleaned)

    let content = cleaned.joined(separator: "\n").normalizedWhitespace()
    if content.isEmpty {
        throw BookError.malformedDocument("No textual content extracted from Kindle file")
    }

    let chapter = Chapter(
        id: "kindle-1",
        href: "kindle://chapter/1",
        title: title,
        content: content
    )

    return Book(
        id: UUID().uuidString,
        format: format,
        version: format == .azw3 ? "8" : "6",
        metadata: Metadata(title: title, authors: authors),
        readingOrder: [chapter],
        assets: [],
        tableOfContents: [TOCNode(title: title, href: chapter.href)],
        landmarks: [],
        pageList: [],
        rawExtensions: [:],
        diagnostics: []
    )
}

private func chooseTitle(from strings: [String]) -> String? {
    for value in strings {
        let lower = value.lowercased()
        if lower == "bookmobi" || lower.hasPrefix("kindle:") {
            continue
        }
        if value.count < 2 || value.count > 120 {
            continue
        }
        if value.contains(":") && !value.contains(" ") {
            continue
        }
        if value.range(of: "^[A-Za-z0-9][A-Za-z0-9 '\\-]{1,119}$", options: .regularExpression) != nil {
            return value
        }
    }
    return nil
}

private func chooseAuthors(from strings: [String]) -> [String] {
    strings.filter {
        $0.count > 3 && $0.count < 80 &&
            $0.contains(" ") &&
            !$0.lowercased().contains("http") &&
            $0.range(of: "^[A-Z][A-Za-z\\-']+( [A-Z][A-Za-z\\-']+)+$", options: .regularExpression) != nil
    }
    .prefix(3)
    .map { $0 }
}
