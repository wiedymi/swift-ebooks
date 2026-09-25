import Foundation

enum SanitizeContent {
    public static func run(_ htmlOrText: String, allowsNetwork: Bool = false) -> String {
        var output = htmlOrText

        output = output.replacingOccurrences(
            of: "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        output = output.replacingOccurrences(
            of: "\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        output = output.replacingOccurrences(
            of: "javascript\\s*:",
            with: "about:blank#blocked-",
            options: [.regularExpression, .caseInsensitive]
        )

        for tag in ["iframe", "object"] {
            output = output.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>.*?<\\/\(tag)\\s*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        output = output.replacingOccurrences(
            of: "<embed\\b[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: "<meta\\b(?=[^>]*\\bhttp-equiv\\s*=\\s*['\"]?refresh)[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: "<\\/?form\\b[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        output = blockResourceAttributes(in: output, schemes: "file")

        if !allowsNetwork {
            output = blockResourceAttributes(in: output, schemes: "https?")
            output = output.replacingOccurrences(
                of: "<(?:link|image|use)\\b(?=[^>]*\\bhref\\s*=\\s*['\"]?\\s*https?://)[^>]*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            output = blockRemoteCSSURLs(in: output)
        }

        return output
    }

    public static func css(_ css: String, allowsNetwork: Bool = false) -> String {
        var output = css
        output = output.replacingOccurrences(
            of: "(?i)expression\\s*\\(",
            with: "blocked-expression( ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "(?i)url\\(\\s*(['\"]?)\\s*(?:javascript|file):[^)]*\\)",
            with: "url(\"about:blank#blocked-resource\")",
            options: .regularExpression
        )
        if !allowsNetwork {
            output = output.replacingOccurrences(
                of: "(?i)@import\\s+(?:url\\()?\\s*['\"]?https?://[^;]+;?",
                with: "",
                options: .regularExpression
            )
            output = blockRemoteCSSURLs(in: output)
        }
        return output
    }

    private static func blockResourceAttributes(in html: String, schemes: String) -> String {
        var output = html
        output = output.replacingOccurrences(
            of: "(?i)(\\s(?:src|srcset|poster|data|action|formaction)\\s*=\\s*['\"])\\s*(?:\(schemes)):[^'\"]*",
            with: "$1about:blank#blocked-resource",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "(?i)(\\s(?:src|srcset|poster|data|action|formaction)\\s*=\\s*)(?:\(schemes)):[^\\s>]+",
            with: "$1about:blank#blocked-resource",
            options: .regularExpression
        )
        return output
    }

    private static func blockRemoteCSSURLs(in input: String) -> String {
        input.replacingOccurrences(
            of: "(?i)url\\(\\s*(['\"]?)\\s*https?://[^)]*\\)",
            with: "url(\"about:blank#blocked-remote\")",
            options: .regularExpression
        )
    }
}

enum ResolveStyles {
    public static func run(baseCSS: String, theme: Theme, typography: Typography) -> String {
        let css = """
        :root {
          --bookkit-bg: \(theme.backgroundColor);
          --bookkit-fg: \(theme.textColor);
          --bookkit-link: \(theme.linkColor);
          --bookkit-selection-bg: \(theme.selectionBackgroundColor);
          --bookkit-selection-fg: \(theme.selectionTextColor);
          --bookkit-font-family: \(typography.cssFontFamilies);
          --bookkit-font-size: \(typography.fontSize)px;
          --bookkit-line-height: \(typography.lineHeight);
          --bookkit-letter-spacing: \(typography.letterSpacing)px;
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bookkit-bg);
          color: var(--bookkit-fg);
          font-family: var(--bookkit-font-family);
          font-size: var(--bookkit-font-size);
          line-height: var(--bookkit-line-height);
          letter-spacing: var(--bookkit-letter-spacing);
        }
        a { color: var(--bookkit-link); }
        ::selection {
          background-color: var(--bookkit-selection-bg) !important;
          color: var(--bookkit-selection-fg) !important;
          -webkit-text-fill-color: var(--bookkit-selection-fg) !important;
          text-shadow: none !important;
        }
        html[data-bookkit-layout="reflowable"] body {
          overflow-wrap: anywhere;
          -webkit-text-size-adjust: 100%;
        }
        html[data-bookkit-layout="reflowable"] img,
        html[data-bookkit-layout="reflowable"] svg,
        html[data-bookkit-layout="reflowable"] video {
          max-width: 100%;
          max-height: calc(100vh - 48px);
          object-fit: contain;
          break-inside: avoid;
        }
        html[data-bookkit-layout="reflowable"] body * {
          box-sizing: border-box;
          max-width: 100% !important;
          min-width: 0 !important;
        }
        html[data-bookkit-layout="reflowable"] pre { white-space: pre-wrap; }
        html[data-bookkit-layout="reflowable"] table { max-width: 100%; table-layout: fixed; }
        \(baseCSS)
        \(theme.customCSS)
        """

        return css
    }
}

enum ResolveLinks {
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

enum Normalize {
    public static func run(_ book: Book, allowsNetwork: Bool = false) -> Book {
        var normalized = book

        normalized.metadata.title = normalized.metadata.title.normalizedWhitespace()
        normalized.metadata.authors = normalized.metadata.authors.map { $0.normalizedWhitespace() }.filter { !$0.isEmpty }

        normalized.readingOrder = normalized.readingOrder.map { chapter in
            var c = chapter
            c.title = c.title?.normalizedWhitespace()
            c.content = SanitizeContent.run(chapter.content, allowsNetwork: allowsNetwork)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return c
        }

        normalized.tableOfContents = normalized.tableOfContents.map(normalizeNavigationNode)
        normalized.landmarks = normalized.landmarks.map(normalizeNavigationNode)
        normalized.pageList = normalized.pageList.map(normalizeNavigationNode)

        if normalized.metadata.title.isEmpty {
            normalized.metadata.title = normalized.readingOrder.first?.title ?? "Untitled"
        }

        return normalized
    }

    private static func normalizeNavigationNode(_ node: TOCNode) -> TOCNode {
        TOCNode(
            id: node.id,
            title: node.title.normalizedWhitespace(),
            href: node.href.normalizedWhitespace(),
            roles: node.roles,
            children: node.children.map(normalizeNavigationNode)
        )
    }
}

/// Reusable text index. Build off the main actor for large books.
public struct SearchIndex: Sendable {
    private let lines: [(chapterID: String, text: String, chapterIndex: Int)]

    public init(book: Book) {
        let html = BookPresentationEngine(book: book).requiresReflowBridge
        lines = book.readingOrder.enumerated().map { index, chapter in
            (chapter.id, (try? BookText.extract(chapter.content, isHTML: html)) ?? "", index)
        }
    }

    public func find(_ query: String, options: SearchOptions = .init()) -> [SearchResult] {
        var result: [SearchResult] = []
        for entry in lines {
            var remaining = options
            remaining.maximumResults = options.maximumResults - result.count
            if remaining.maximumResults <= 0 { break }
            result += BookText.matches(query, text: entry.text, chapterID: entry.chapterID, index: entry.chapterIndex, options: remaining)
        }
        return result
    }
}
