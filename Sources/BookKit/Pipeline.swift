import Foundation

public enum SanitizeContent {
    public static func run(_ htmlOrText: String) -> String {
        var output = htmlOrText

        // Strip script tags completely.
        output = output.replacingOccurrences(
            of: "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove inline event handlers.
        output = output.replacingOccurrences(
            of: "\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Rewrite javascript: links to safe placeholders.
        output = output.replacingOccurrences(
            of: "javascript\\s*:",
            with: "about:blank#blocked-",
            options: [.regularExpression, .caseInsensitive]
        )

        return output
    }
}

public enum ResolveStyles {
    public static func run(baseCSS: String, theme: Theme, typography: Typography) -> String {
        let css = """
        :root {
          --bookkit-bg: \(theme.backgroundColor);
          --bookkit-fg: \(theme.textColor);
          --bookkit-link: \(theme.linkColor);
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bookkit-bg);
          color: var(--bookkit-fg);
          font-family: \(typography.fontFamily);
          font-size: \(typography.fontSize)px;
          line-height: \(typography.lineHeight);
          letter-spacing: \(typography.letterSpacing)px;
        }
        a { color: var(--bookkit-link); }
        \(baseCSS)
        \(theme.customCSS)
        """

        return css
    }
}

public enum ResolveLinks {
    public static func classify(_ url: URL) -> LinkKind {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https": return .external
            case "javascript": return .unsupported
            case "bookkit":
                if let fragment = url.fragment, !fragment.isEmpty {
                    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if path.isEmpty || path == "current" {
                        return .anchor
                    }
                }
                if !url.path.isEmpty, url.path != "/" {
                    return .spine
                }
                return .unsupported
            case "file": return .unsupported
            default: return .unsupported
            }
        }

        if let fragment = url.fragment, !fragment.isEmpty {
            if url.path.isEmpty { return .anchor }
            return .spine
        }

        if !url.path.isEmpty {
            return .spine
        }

        return .unsupported
    }
}

public enum Normalize {
    public static func run(_ book: Book) -> Book {
        var normalized = book

        normalized.metadata.title = normalized.metadata.title.normalizedWhitespace()
        normalized.metadata.authors = normalized.metadata.authors.map { $0.normalizedWhitespace() }.filter { !$0.isEmpty }

        normalized.readingOrder = normalized.readingOrder.map { chapter in
            var c = chapter
            c.title = c.title?.normalizedWhitespace()
            c.content = SanitizeContent.run(chapter.content).normalizedWhitespace()
            return c
        }

        normalized.tableOfContents = normalized.tableOfContents.map { node in
            TOCNode(title: node.title.normalizedWhitespace(), href: node.href.normalizedWhitespace())
        }

        if normalized.metadata.title.isEmpty {
            normalized.metadata.title = normalized.readingOrder.first?.title ?? "Untitled"
        }

        return normalized
    }
}

public struct SearchIndex: Sendable {
    private let lines: [(chapterID: String, text: String, chapterIndex: Int)]

    public init(book: Book) {
        self.lines = book.readingOrder.enumerated().map { idx, chapter in
            (chapter.id, chapter.content.lowercased(), idx)
        }
    }

    public func find(_ query: String) -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        return lines.compactMap { entry in
            guard let range = entry.text.range(of: needle) else { return nil }
            let offset = entry.text.distance(from: entry.text.startIndex, to: range.lowerBound)
            let len = max(entry.text.count, 1)
            return SearchResult(
                chapterID: entry.chapterID,
                position: Position(spineIndex: entry.chapterIndex, progression: Double(offset) / Double(len)),
                snippet: "...\(needle)..."
            )
        }
    }
}
