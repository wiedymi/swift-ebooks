import Foundation

public struct FB2Parser: BookParser {
    public let formats: Set<BookFormat> = [.fb2]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        var data = try source.loadData(options: options)
        var effectiveFileName = source.fileName
        var isCompressed = false
        if data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) {
            let archive = try SafeZIPArchive(data: data, options: options, kind: "FB2")
            let documents = archive.files.map(\.path).filter {
                ($0 as NSString).pathExtension.caseInsensitiveCompare("fb2") == .orderedSame
            }
            guard documents.count == 1, let path = documents.first else {
                throw BookError.invalidContainer(
                    "Compressed FB2 must contain exactly one .fb2 document"
                )
            }
            guard let payload = try archive.data(at: path) else {
                throw BookError.invalidContainer("Unable to extract compressed FB2 document")
            }
            data = payload
            effectiveFileName = (path as NSString).lastPathComponent
            isCompressed = true
        }
        let root = try FB2XML.parse(data)
        guard root.localName == "FictionBook" else {
            throw BookError.invalidContainer("FB2 root element is not FictionBook")
        }

        let description = root.child(named: "description")
        let titleInfo = description?.child(named: "title-info")
        let documentInfo = description?.child(named: "document-info")
        let publishInfo = description?.child(named: "publish-info")

        let title = titleInfo?.child(named: "book-title")?.plainText.normalizedWhitespace()
            .nonEmpty ?? effectiveFileName ?? "Untitled"
        let authors = titleInfo?.children(named: "author").compactMap(authorName) ?? []
        let language = titleInfo?.child(named: "lang")?.plainText.normalizedWhitespace().nonEmpty
        let publisher = publishInfo?.child(named: "publisher")?.plainText.normalizedWhitespace().nonEmpty
        let publicationDate = titleInfo?.child(named: "date")?.attribute(named: "value")
            ?? titleInfo?.child(named: "date")?.plainText.normalizedWhitespace().nonEmpty
        let documentID = documentInfo?.child(named: "id")?.plainText.normalizedWhitespace().nonEmpty
        let bookID = documentID ?? DeterministicIdentifier.make(namespace: "fb2", data: data)

        var diagnostics: [BookDiagnostic] = []
        let assets = root.children(named: "binary").compactMap { node -> Asset? in
            guard let id = node.attribute(named: "id")?.nonEmpty else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "fb2.binary-missing-id",
                        message: "Ignored an FB2 binary without an id"
                    )
                )
                return nil
            }
            let compactBase64 = node.plainText.filter { !$0.isWhitespace }
            guard let payload = Data(base64Encoded: compactBase64) else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "fb2.invalid-binary",
                        message: "Unable to decode FB2 binary \(id)",
                        location: id
                    )
                )
                return Asset(
                    id: id,
                    href: id,
                    mediaType: node.attribute(named: "content-type") ?? "application/octet-stream"
                )
            }
            return Asset(
                id: id,
                href: id,
                mediaType: node.attribute(named: "content-type") ?? "application/octet-stream",
                data: payload
            )
        }

        let publicationCSS = root.children(named: "stylesheet")
            .map(\.plainText)
            .joined(separator: "\n")
        let styleElement = publicationCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "<style data-bookkit-publication>\(publicationCSS)</style>\n"

        var chapters: [Chapter] = []
        var tableOfContents: [TOCNode] = []
        var landmarks: [TOCNode] = []
        let bodies = root.children(named: "body")

        for (bodyIndex, body) in bodies.enumerated() {
            let isNotes = body.attribute(named: "name")?.lowercased() == "notes"
            let bodyTitle = body.child(named: "title")?.plainText.normalizedWhitespace().nonEmpty
                ?? (isNotes ? "Notes" : title)
            let topSections = body.children(named: "section")
            let preamble = body.childElements.filter { $0.localName != "section" }

            if !preamble.isEmpty {
                let chapterID = "body-\(bodyIndex + 1)-preamble"
                let href = "fb2/\(chapterID).xhtml"
                let html = styleElement + preamble.map { FB2HTML.render($0) }.joined(separator: "\n")
                if !html.strippingHTML().normalizedWhitespace().isEmpty {
                    chapters.append(
                        Chapter(id: chapterID, href: href, title: bodyTitle, content: html)
                    )
                    let navigation = TOCNode(title: bodyTitle, href: href)
                    tableOfContents.append(navigation)
                    if isNotes {
                        var landmark = navigation
                        landmark.roles = ["footnotes"]
                        landmarks.append(landmark)
                    }
                }
            }

            for (sectionIndex, section) in topSections.enumerated() {
                let fallbackID = "body-\(bodyIndex + 1)-section-\(sectionIndex + 1)"
                let sectionID = FB2HTML.domID(section.attribute(named: "id") ?? fallbackID)
                let href = "fb2/\(sectionID).xhtml"
                let sectionTitle = FB2HTML.title(for: section)
                    ?? (isNotes ? "Notes" : "Section \(sectionIndex + 1)")
                let html = styleElement + FB2HTML.render(section, forcedID: sectionID)
                guard !html.strippingHTML().normalizedWhitespace().isEmpty else {
                    continue
                }
                chapters.append(
                    Chapter(id: sectionID, href: href, title: sectionTitle, content: html)
                )
                let navigation = FB2HTML.navigationNode(
                    for: section,
                    chapterHref: href,
                    fallbackTitle: sectionTitle,
                    fallbackID: sectionID
                )
                tableOfContents.append(navigation)
                if isNotes {
                    landmarks.append(
                        TOCNode(
                            id: "landmark-\(sectionID)",
                            title: sectionTitle,
                            href: navigation.href,
                            roles: ["footnotes"]
                        )
                    )
                }
            }
        }

        if chapters.isEmpty {
            throw BookError.malformedDocument("FB2 content is empty")
        }

        var identifiers: [String: String] = [:]
        if let documentID {
            identifiers["primary"] = documentID
        }

        return Book(
            id: bookID,
            format: .fb2,
            version: "2.0",
            metadata: Metadata(
                title: title,
                authors: authors,
                language: language,
                identifiers: identifiers,
                publisher: publisher,
                publicationDate: publicationDate
            ),
            readingOrder: chapters,
            assets: assets,
            tableOfContents: tableOfContents,
            landmarks: landmarks,
            pageList: [],
            rawExtensions: isCompressed ? ["bookkit:container": "fb2.zip"] : [:],
            diagnostics: diagnostics
        )
    }

    private func authorName(_ author: FB2XMLNode) -> String? {
        let first = author.child(named: "first-name")?.plainText.normalizedWhitespace().nonEmpty
        let last = author.child(named: "last-name")?.plainText.normalizedWhitespace().nonEmpty
        let structured = [first, last].compactMap { $0 }.joined(separator: " ")
        if let value = structured.nonEmpty {
            return value
        }
        return author.child(named: "nickname")?.plainText.normalizedWhitespace().nonEmpty
    }
}

private final class FB2XMLNode {
    enum Content {
        case text(String)
        case element(FB2XMLNode)
    }

    let name: String
    let attributes: [String: String]
    var content: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    var childElements: [FB2XMLNode] {
        content.compactMap { item in
            guard case let .element(node) = item else { return nil }
            return node
        }
    }

    var plainText: String {
        content.map { item in
            switch item {
            case let .text(value): return value
            case let .element(node): return node.plainText
            }
        }.joined(separator: " ")
    }

    func child(named name: String) -> FB2XMLNode? {
        childElements.first { $0.localName == name }
    }

    func children(named name: String) -> [FB2XMLNode] {
        childElements.filter { $0.localName == name }
    }

    func attribute(named name: String) -> String? {
        if let value = attributes[name] {
            return value
        }
        return attributes.first(where: {
            ($0.key.split(separator: ":").last.map(String.init) ?? $0.key) == name
        })?.value
    }
}

private enum FB2XML {
    static func parse(_ data: Data) throws -> FB2XMLNode {
        let delegate = FB2XMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw BookError.malformedDocument(
                parser.parserError?.localizedDescription ?? "Unable to parse FB2 XML"
            )
        }
        return root
    }
}

private final class FB2XMLDelegate: NSObject, XMLParserDelegate {
    var root: FB2XMLNode?
    private var stack: [FB2XMLNode] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = FB2XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.content.append(.element(node))
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        stack.last?.content.append(.text(string))
    }

    func parser(
        _: XMLParser,
        didEndElement _: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        _ = stack.popLast()
    }
}

private enum FB2HTML {
    static func render(_ node: FB2XMLNode, forcedID: String? = nil) -> String {
        let effectiveID = forcedID ?? node.attribute(named: "id")
        var nestedSectionIndex = 0
        let content = node.content.map { item in
            switch item {
            case let .text(value): return escapeText(value)
            case let .element(child):
                if child.localName == "section" {
                    nestedSectionIndex += 1
                    let childID = child.attribute(named: "id")
                        ?? "\(effectiveID ?? "section")-\(nestedSectionIndex)"
                    return render(child, forcedID: domID(childID))
                }
                return render(child)
            }
        }.joined()
        let attributes = htmlAttributes(for: node, forcedID: forcedID)

        switch node.localName {
        case "section": return "<section\(attributes)>\(content)</section>"
        case "title": return "<header class=\"fb2-title\"\(attributes)>\(content)</header>"
        case "subtitle": return "<h3\(attributes)>\(content)</h3>"
        case "p": return "<p\(attributes)>\(content)</p>"
        case "emphasis": return "<em\(attributes)>\(content)</em>"
        case "strong": return "<strong\(attributes)>\(content)</strong>"
        case "strikethrough": return "<s\(attributes)>\(content)</s>"
        case "sub": return "<sub\(attributes)>\(content)</sub>"
        case "sup": return "<sup\(attributes)>\(content)</sup>"
        case "code": return "<code\(attributes)>\(content)</code>"
        case "epigraph", "cite", "poem":
            return "<blockquote class=\"fb2-\(node.localName)\"\(attributes)>\(content)</blockquote>"
        case "stanza": return "<div class=\"fb2-stanza\"\(attributes)>\(content)</div>"
        case "v": return "<p class=\"fb2-verse\"\(attributes)>\(content)</p>"
        case "text-author": return "<p class=\"fb2-text-author\"\(attributes)>\(content)</p>"
        case "date": return "<time\(attributes)>\(content)</time>"
        case "empty-line": return "<br\(attributes)>"
        case "image":
            let rawHref = node.attribute(named: "href") ?? ""
            let assetID = String(rawHref.drop(while: { $0 == "#" }))
            let source = assetID.isEmpty ? "" : "bookkit://asset/\(assetID)"
            let alt = node.attribute(named: "alt") ?? node.attribute(named: "title") ?? ""
            return "<img\(attributes) src=\"\(escapeAttribute(source))\" alt=\"\(escapeAttribute(alt))\">"
        case "a":
            let href = node.attribute(named: "href") ?? ""
            return "<a\(attributes) href=\"\(escapeAttribute(href))\">\(content)</a>"
        default:
            return content
        }
    }

    static func title(for section: FB2XMLNode) -> String? {
        section.child(named: "title")?.plainText.normalizedWhitespace().nonEmpty
            ?? section.child(named: "subtitle")?.plainText.normalizedWhitespace().nonEmpty
    }

    static func navigationNode(
        for section: FB2XMLNode,
        chapterHref: String,
        fallbackTitle: String,
        fallbackID: String
    ) -> TOCNode {
        let sectionID = domID(section.attribute(named: "id") ?? fallbackID)
        let children = section.children(named: "section").enumerated().map { index, child in
            navigationNode(
                for: child,
                chapterHref: chapterHref,
                fallbackTitle: title(for: child) ?? "Section \(index + 1)",
                fallbackID: "\(sectionID)-\(index + 1)"
            )
        }
        return TOCNode(
            id: "toc-\(sectionID)",
            title: title(for: section) ?? fallbackTitle,
            href: "\(chapterHref)#\(sectionID)",
            children: children
        )
    }

    static func domID(_ value: String) -> String {
        let normalized = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "-"
        }
        let result = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.nonEmpty ?? "section"
    }

    private static func htmlAttributes(for node: FB2XMLNode, forcedID: String?) -> String {
        var attributes: [String] = []
        if let id = forcedID ?? node.attribute(named: "id")?.nonEmpty {
            attributes.append("id=\"\(escapeAttribute(domID(id)))\"")
        }
        if let language = node.attribute(named: "lang")?.nonEmpty {
            attributes.append("lang=\"\(escapeAttribute(language))\"")
        }
        if let style = node.attribute(named: "style")?.nonEmpty {
            attributes.append("data-fb2-style=\"\(escapeAttribute(style))\"")
        }
        return attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
