import Foundation

public struct Metadata: Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var language: String?
    public var identifiers: [String: String]
    public var publisher: String?
    public var publicationDate: String?

    public init(
        title: String,
        authors: [String],
        language: String? = nil,
        identifiers: [String: String] = [:],
        publisher: String? = nil,
        publicationDate: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.language = language
        self.identifiers = identifiers
        self.publisher = publisher
        self.publicationDate = publicationDate
    }
}

public struct Chapter: Sendable, Equatable {
    public var id: String
    public var href: String
    public var title: String?
    public var content: String

    public init(id: String, href: String, title: String?, content: String) {
        self.id = id
        self.href = href
        self.title = title
        self.content = content
    }
}

public struct Asset: Sendable, Equatable {
    public var id: String
    public var href: String
    public var mediaType: String
    public var data: Data?

    public init(id: String, href: String, mediaType: String, data: Data? = nil) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.data = data
    }
}

public struct TOCNode: Sendable, Equatable {
    public var title: String
    public var href: String

    public init(title: String, href: String) {
        self.title = title
        self.href = href
    }
}

public struct BookDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable {
        case info
        case warning
        case error
    }

    public var severity: Severity
    public var code: String
    public var message: String
    public var location: String?

    public init(severity: Severity, code: String, message: String, location: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
    }
}

public typealias BookDiagnostics = [BookDiagnostic]

public struct TextContext: Sendable, Equatable, Hashable, Codable {
    public var prefix: String
    public var suffix: String

    public init(prefix: String, suffix: String) {
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct Position: Sendable, Equatable, Hashable, Codable {
    public var spineIndex: Int
    public var progression: Double
    public var cfi: String?
    public var fragment: String?
    public var textContext: TextContext?

    public init(
        spineIndex: Int,
        progression: Double,
        cfi: String? = nil,
        fragment: String? = nil,
        textContext: TextContext? = nil
    ) {
        self.spineIndex = spineIndex
        self.progression = progression
        self.cfi = cfi
        self.fragment = fragment
        self.textContext = textContext
    }
}

public extension Position {
    static let start = Position(spineIndex: 0, progression: 0)
}

public struct SearchResult: Sendable, Equatable {
    public var chapterID: String
    public var position: Position
    public var snippet: String

    public init(chapterID: String, position: Position, snippet: String) {
        self.chapterID = chapterID
        self.position = position
        self.snippet = snippet
    }
}

public struct Book: Sendable, Equatable {
    public var id: String
    public var format: BookFormat
    public var version: String
    public var metadata: Metadata
    public var readingOrder: [Chapter]
    public var assets: [Asset]
    public var tableOfContents: [TOCNode]
    public var landmarks: [TOCNode]
    public var pageList: [TOCNode]
    public var rawExtensions: [String: String]
    public var diagnostics: [BookDiagnostic]

    public init(
        id: String,
        format: BookFormat,
        version: String,
        metadata: Metadata,
        readingOrder: [Chapter],
        assets: [Asset],
        tableOfContents: [TOCNode],
        landmarks: [TOCNode],
        pageList: [TOCNode],
        rawExtensions: [String: String],
        diagnostics: [BookDiagnostic]
    ) {
        self.id = id
        self.format = format
        self.version = version
        self.metadata = metadata
        self.readingOrder = readingOrder
        self.assets = assets
        self.tableOfContents = tableOfContents
        self.landmarks = landmarks
        self.pageList = pageList
        self.rawExtensions = rawExtensions
        self.diagnostics = diagnostics
    }
}

public extension Book {
    static func open(
        from url: URL,
        options: OpenOptions = OpenOptions(),
        registry: ParserRegistry = .default
    ) async throws -> Book {
        try await open(source: .url(url), options: options, registry: registry)
    }

    static func open(
        source: BookSource,
        options: OpenOptions = OpenOptions(),
        registry: ParserRegistry = .default
    ) async throws -> Book {
        let data: Data
        do {
            data = try source.loadData(options: options)
        } catch {
            throw BookError.from(error)
        }

        guard let format = FormatSniffer.detect(data: data, fileName: source.fileName) else {
            throw BookError.unsupportedFormat
        }

        guard let parser = registry.parser(for: format) else {
            throw BookError.unsupportedFormat
        }

        do {
            return try await parser.parse(source: .data(data, fileName: source.fileName), options: options)
        } catch {
            throw BookError.from(error)
        }
    }

    func search(_ query: String) async throws -> [SearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return []
        }

        let needle = normalized.lowercased()
        var results: [SearchResult] = []

        for (chapterIndex, chapter) in readingOrder.enumerated() {
            let haystack = chapter.content.lowercased()
            guard let range = haystack.range(of: needle) else {
                continue
            }

            let lower = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let upper = haystack.distance(from: haystack.startIndex, to: range.upperBound)
            let chapterLen = max(chapter.content.count, 1)
            let progression = Double(lower) / Double(chapterLen)

            let snippetStart = max(lower - 40, 0)
            let snippetEnd = min(upper + 40, chapter.content.count)
            let startIdx = chapter.content.index(chapter.content.startIndex, offsetBy: snippetStart)
            let endIdx = chapter.content.index(chapter.content.startIndex, offsetBy: snippetEnd)
            let snippet = String(chapter.content[startIdx..<endIdx])

            results.append(
                SearchResult(
                    chapterID: chapter.id,
                    position: Position(spineIndex: chapterIndex, progression: progression),
                    snippet: snippet
                )
            )
        }

        return results
    }
}
