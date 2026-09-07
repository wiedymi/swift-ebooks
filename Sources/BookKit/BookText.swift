import Foundation
import SwiftSoup

/// UTF-16 offsets in normalized chapter text, with a quote for recovery after edits.
/// The end offset is exclusive. Offsets are hints; the quote must also match.
public struct ReaderTextRange: Sendable, Equatable, Hashable, Codable {
    public var start: Int
    public var end: Int
    public var quote: String
    public var prefix: String
    public var suffix: String

    public init(start: Int, end: Int, quote: String, prefix: String = "", suffix: String = "") {
        self.start = max(0, start)
        self.end = max(self.start, end)
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct SearchOptions: Sendable, Equatable {
    public var caseSensitive: Bool
    public var diacriticSensitive: Bool
    /// Maximum number of returned matches. Values less than one return no matches.
    public var maximumResults: Int

    public init(caseSensitive: Bool = false, diacriticSensitive: Bool = true, maximumResults: Int = 10_000) {
        self.caseSensitive = caseSensitive
        self.diacriticSensitive = diacriticSensitive
        self.maximumResults = maximumResults
    }
}

/// Text and location that an app can pass to any speech or dubbing service.
public struct ReadingText: Sendable, Equatable {
    public var text: String
    public var locator: Locator

    public init(text: String, locator: Locator) {
        self.text = text
        self.locator = locator
    }
}

extension Book {
    /// Extracts readable text. Image-only pages return an empty string.
    @concurrent
    public func text(inSection index: Int) async throws -> String {
        guard readingOrder.indices.contains(index) else {
            throw BookError.navigationFailed("Section index is out of range")
        }
        try Task.checkCancellation()
        return try BookText.extract(
            readingOrder[index].content, isHTML: BookPresentationEngine(book: self).requiresReflowBridge)
    }

    /// Sentence-sized text with portable locations for speech and synchronized marks.
    /// Long sentences are split at a word boundary when possible.
    @concurrent
    public func readingText(inSection index: Int, maximumUTF16Length: Int = 2_000) async throws
        -> [ReadingText]
    {
        guard maximumUTF16Length >= 2 else {
            throw BookError.renderingFailed("Speech text length must be at least two UTF-16 units")
        }
        let text = try await text(inSection: index)
        let source = text as NSString
        let length = max(source.length, 1)
        var result: [ReadingText] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, range, _, stop in
            if Task.isCancelled {
                stop = true
                return
            }
            let sentence = NSRange(range, in: text)
            var cursor = sentence.location
            let limit = cursor + sentence.length
            while cursor < limit {
                if Task.isCancelled {
                    stop = true
                    return
                }
                var end = cursor + min(maximumUTF16Length, limit - cursor)
                if end < limit {
                    if (0xDC00...0xDFFF).contains(source.character(at: end)) { end -= 1 }
                    let space = source.range(
                        of: " ", options: .backwards, range: NSRange(location: cursor, length: end - cursor))
                    if space.location != NSNotFound, space.location > cursor + (end - cursor) / 2 {
                        end = space.location + 1
                    }
                }
                let target = BookText.range(
                    in: source, range: NSRange(location: cursor, length: end - cursor))
                let position = Position(
                    spineIndex: index, progression: Double(cursor) / Double(length), textRange: target)
                result.append(ReadingText(text: target.quote, locator: locator(for: position)))
                cursor = end
            }
        }
        try Task.checkCancellation()
        return result
    }

}

enum BookText {
    // Keep these separators and exclusions aligned with the DOM text map.
    static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "table", "td", "th", "tr", "ul",
    ]
    static let excluded: Set<String> = ["script", "style", "head", "template", "noscript"]

    static func extract(_ content: String, isHTML: Bool) throws -> String {
        guard isHTML else { return normalize(content) }
        let document = try SwiftSoup.parse(content)
        guard let body = document.body() else { return "" }
        var output = ""
        // An explicit stack avoids recursion on deeply nested publications.
        var pending: [(Node, Bool)] = [(body, false)]
        while let (node, closing) = pending.popLast() {
            try Task.checkCancellation()
            if let text = node as? TextNode {
                output += text.getWholeText()
            } else if let element = node as? Element {
                let tag = element.tagName().lowercased()
                let ariaHidden = try element.attr("aria-hidden")
                if excluded.contains(tag) || element.hasAttr("hidden") || ariaHidden == "true" { continue }
                let inline = try element.attr("style").lowercased().replacingOccurrences(of: " ", with: "")
                if inline.contains("display:none") || inline.contains("visibility:hidden") { continue }
                if blocks.contains(tag) { output += " " }
                if !closing {
                    pending.append((node, true))
                    pending.append(contentsOf: node.getChildNodes().reversed().map { ($0, false) })
                }
            }
        }
        return normalize(output)
    }

    static func normalize(_ text: String) -> String {
        NormalizedText(text).text
    }

    static func range(in text: String, range: NSRange) -> ReaderTextRange {
        self.range(in: text as NSString, range: range)
    }

    static func range(in source: NSString, range: NSRange) -> ReaderTextRange {
        let start = range.location
        let end = start + range.length
        var prefixStart = max(0, start - 32)
        var suffixEnd = end + min(32, source.length - end)
        if prefixStart < start, (0xDC00...0xDFFF).contains(source.character(at: prefixStart)) {
            prefixStart += 1
        }
        if suffixEnd < source.length, suffixEnd > end,
            (0xDC00...0xDFFF).contains(source.character(at: suffixEnd))
        {
            suffixEnd -= 1
        }
        return ReaderTextRange(
            start: start, end: end, quote: source.substring(with: range),
            prefix: source.substring(with: NSRange(location: prefixStart, length: start - prefixStart)),
            suffix: source.substring(with: NSRange(location: end, length: suffixEnd - end)))
    }

    static func matches(_ query: String, text: String, chapterID: String, index: Int, options: SearchOptions)
        -> [SearchResult]
    {
        let needle = normalize(query)
        guard !needle.isEmpty, options.maximumResults > 0 else { return [] }
        var compare: String.CompareOptions = []
        if !options.caseSensitive { compare.insert(.caseInsensitive) }
        if !options.diacriticSensitive { compare.insert(.diacriticInsensitive) }
        let source = text as NSString
        let length = source.length
        var results: [SearchResult] = []
        var cursor = 0
        while cursor < length, results.count < options.maximumResults, !Task.isCancelled {
            let match = source.range(
                of: needle, options: compare, range: NSRange(location: cursor, length: length - cursor))
            guard match.location != NSNotFound, match.length > 0 else { break }
            let target = range(in: source, range: match)
            results.append(
                SearchResult(
                    chapterID: chapterID,
                    position: Position(
                        spineIndex: index, progression: Double(target.start) / Double(max(length, 1)),
                        textRange: target),
                    snippet: target.prefix + target.quote + target.suffix))
            cursor = match.location + match.length
        }
        return results
    }
}
