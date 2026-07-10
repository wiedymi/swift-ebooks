import Foundation

public protocol BookParser: Sendable {
    var formats: Set<BookFormat> { get }
    func parse(source: BookSource, options: OpenOptions) async throws -> Book
}

public struct ParserRegistry: Sendable {
    private let parsers: [any BookParser]

    public init(parsers: [any BookParser]) {
        self.parsers = parsers
    }

    public func parser(for format: BookFormat) -> (any BookParser)? {
        parsers.first { $0.formats.contains(format) }
    }

    public static let `default` = ParserRegistry(parsers: [
        EPUBParser(),
        FB2Parser(),
        MOBIParser(),
        AZW3Parser(),
        PDFParser(),
    ])
}
