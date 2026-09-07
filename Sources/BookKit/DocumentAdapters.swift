import Foundation

struct TextDocumentParser: BookParser {
    public let formats: Set<BookFormat> = [.text, .html, .markdown]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try await source.loadData(options: options)
        guard let text = Self.decode(data) else {
            throw BookError.malformedDocument("Unable to decode document text as UTF-8 or Unicode")
        }
        guard let format = source.fileName.flatMap(FormatSniffer.detect(fileName:))
            ?? FormatSniffer.detect(data: data, fileName: nil),
            formats.contains(format)
        else {
            throw BookError.unsupportedFormat
        }

        switch format {
        case .html:
            return parseHTML(text, source: source, data: data)
        case .markdown:
            return parseMarkdown(text, source: source, data: data)
        case .text:
            return parsePlainText(text, source: source, data: data)
        default:
            throw BookError.unsupportedFormat
        }
    }

    private func parsePlainText(_ text: String, source: BookSource, data: Data) -> Book {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let firstLine = normalized.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?.normalizedWhitespace()
        let title = firstLine.flatMap { $0.count <= 160 ? $0.nonEmpty : nil }
            ?? fallbackTitle(source.fileName)
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { escapeHTML(String($0)) }
                    .joined(separator: "<br>")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .map { "<p>\($0)</p>" }
            .joined(separator: "\n")
        return makeBook(
            format: .text,
            title: title,
            href: source.fileName ?? "document.txt",
            content: paragraphs,
            toc: [],
            data: data,
            adapter: "plain-text"
        )
    }

    private func parseHTML(_ html: String, source: BookSource, data: Data) -> Book {
        let href = source.fileName ?? "document.html"
        let indexed = HTMLHeadingIndexer.index(bodyContent(in: html), documentHref: href)
        let title = html.firstMatch(for: "(?is)<title\\b[^>]*>(.*?)</title>")?
            .strippingHTML().normalizedWhitespace().nonEmpty
            ?? indexed.headings.first?.node.title
            ?? fallbackTitle(source.fileName)
        return makeBook(
            format: .html,
            title: title,
            href: href,
            content: indexed.html,
            toc: HeadingTree.make(from: indexed.headings),
            data: data,
            adapter: "html"
        )
    }

    private func parseMarkdown(_ markdown: String, source: BookSource, data: Data) -> Book {
        let href = source.fileName ?? "document.md"
        let rendered = MarkdownRenderer.render(markdown, documentHref: href)
        let title = rendered.headings.first?.node.title ?? fallbackTitle(source.fileName)
        return makeBook(
            format: .markdown,
            title: title,
            href: href,
            content: rendered.html,
            toc: HeadingTree.make(from: rendered.headings),
            data: data,
            adapter: "markdown"
        )
    }

    private func makeBook(
        format: BookFormat,
        title: String,
        href: String,
        content: String,
        toc: [TOCNode],
        data: Data,
        adapter: String
    ) -> Book {
        Book(
            id: DeterministicIdentifier.make(namespace: format.rawValue, data: data),
            format: format,
            version: "1",
            metadata: Metadata(title: title, authors: []),
            readingOrder: [
                Chapter(
                    id: "document",
                    href: href,
                    title: title,
                    content: content,
                    mediaType: "text/html"
                ),
            ],
            assets: [],
            tableOfContents: toc,
            landmarks: [TOCNode(id: "document-start", title: title, href: href, roles: ["bodymatter"])],
            pageList: [],
            rawExtensions: ["bookkit:adapter": adapter],
            diagnostics: []
        )
    }

    private func fallbackTitle(_ fileName: String?) -> String {
        guard let fileName else { return "Untitled" }
        return ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent
    }

    private func bodyContent(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<body\\b[^>]*>(.*?)</body>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
            let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: html)
        else {
            return html
        }
        return String(html[range])
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: Data([0xff, 0xfe])) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: Data([0xfe, 0xff])) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if data.starts(with: Data([0xef, 0xbb, 0xbf])) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct IndexedHeading {
    var level: Int
    var node: TOCNode
}

private enum HeadingTree {
    static func make(from headings: [IndexedHeading]) -> [TOCNode] {
        var index = 0
        return makeLevel(from: headings, index: &index, parentLevel: 0)
    }

    private static func makeLevel(
        from headings: [IndexedHeading],
        index: inout Int,
        parentLevel: Int
    ) -> [TOCNode] {
        var nodes: [TOCNode] = []
        while index < headings.count {
            let heading = headings[index]
            if heading.level <= parentLevel { break }
            var node = heading.node
            let level = heading.level
            index += 1
            if index < headings.count, headings[index].level > level {
                node.children = makeLevel(from: headings, index: &index, parentLevel: level)
            }
            nodes.append(node)
        }
        return nodes
    }
}

private enum HTMLHeadingIndexer {
    static func index(_ html: String, documentHref: String) -> (html: String, headings: [IndexedHeading]) {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<h([1-6])([^>]*)>(.*?)</h\\1>"
        ) else {
            return (html, [])
        }
        let matches = regex.matches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html)
        )
        var usedIDs: Set<String> = []
        var replacements: [(Range<String.Index>, String)] = []
        var headings: [IndexedHeading] = []

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: html),
                  let levelRange = Range(match.range(at: 1), in: html),
                  let attributesRange = Range(match.range(at: 2), in: html),
                  let contentRange = Range(match.range(at: 3), in: html),
                  let level = Int(html[levelRange])
            else {
                continue
            }
            let attributes = String(html[attributesRange])
            let content = String(html[contentRange])
            let title = content.strippingHTML().normalizedWhitespace()
            guard !title.isEmpty else { continue }
            let explicitID = attributes.firstMatch(for: "(?i)\\bid\\s*=\\s*['\"]([^'\"]+)['\"]")
            let id = uniqueSlug(explicitID ?? title, used: &usedIDs)
            let replacement: String
            if explicitID == nil {
                replacement = "<h\(level)\(attributes) id=\"\(id)\">\(content)</h\(level)>"
                replacements.append((fullRange, replacement))
            }
            headings.append(
                IndexedHeading(
                    level: level,
                    node: TOCNode(title: title, href: "\(documentHref)#\(id)")
                )
            )
        }

        var output = html
        for (range, replacement) in replacements.reversed() {
            output.replaceSubrange(range, with: replacement)
        }
        return (output, headings)
    }
}

private enum MarkdownRenderer {
    static func render(_ markdown: String, documentHref: String) -> (html: String, headings: [IndexedHeading]) {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var html: [String] = []
        var headings: [IndexedHeading] = []
        var usedIDs: Set<String> = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var isInCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(renderInline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            html.append("<ul>\(listItems.map { "<li>\(renderInline($0))</li>" }.joined())</ul>")
            listItems.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.hasPrefix("```") {
                if isInCodeBlock {
                    let languageClass = codeLanguage.isEmpty
                        ? ""
                        : " class=\"language-\(escapeAttribute(codeLanguage))\""
                    html.append(
                        "<pre><code\(languageClass)>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>"
                    )
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = ""
                } else {
                    flushParagraph()
                    flushList()
                    codeLanguage = String(line.dropFirst(3)).normalizedWhitespace()
                }
                isInCodeBlock.toggle()
                continue
            }
            if isInCodeBlock {
                codeLines.append(line)
                continue
            }

            if let match = line.firstMatch(for: "^(#{1,6})\\s+(.+?)\\s*#*$") {
                flushParagraph()
                flushList()
                let hashes = line.prefix { $0 == "#" }
                let level = hashes.count
                let rawTitle = String(line.dropFirst(level))
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
                let title = rawTitle.normalizedWhitespace()
                let id = uniqueSlug(title, used: &usedIDs)
                html.append("<h\(level) id=\"\(id)\">\(renderInline(title))</h\(level)>")
                headings.append(
                    IndexedHeading(
                        level: level,
                        node: TOCNode(title: title, href: "\(documentHref)#\(id)")
                    )
                )
                _ = match
                continue
            }

            if let item = line.firstMatch(for: "^\\s*[-*+]\\s+(.+)$") {
                flushParagraph()
                listItems.append(item)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushList()
            } else if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                html.append("<blockquote>\(renderInline(String(line.dropFirst()).normalizedWhitespace()))</blockquote>")
            } else {
                flushList()
                paragraph.append(line.normalizedWhitespace())
            }
        }

        if isInCodeBlock {
            html.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        flushList()
        return (html.joined(separator: "\n"), headings)
    }

    private static func renderInline(_ input: String) -> String {
        var output = escapeHTML(input)
        output = output.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\(([^\\s)]+)\\)",
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        return output
    }
}

private func uniqueSlug(_ input: String, used: inout Set<String>) -> String {
    let folded = input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    var base = folded.lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "section" }
    var candidate = base
    var suffix = 2
    while used.contains(candidate) {
        candidate = "\(base)-\(suffix)"
        suffix += 1
    }
    used.insert(candidate)
    return candidate
}

private func escapeHTML(_ input: String) -> String {
    input.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func escapeAttribute(_ input: String) -> String {
    escapeHTML(input).replacingOccurrences(of: "'", with: "&#39;")
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
