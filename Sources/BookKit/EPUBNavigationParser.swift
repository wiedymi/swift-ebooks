import Foundation

struct EPUBNavigationDocument {
    var tableOfContents: [TOCNode] = []
    var landmarks: [TOCNode] = []
    var pageList: [TOCNode] = []
}

enum EPUBNavigationParser {
    static func parseNavigationDocument(
        _ data: Data,
        documentHref: String
    ) throws -> EPUBNavigationDocument {
        let root = try XMLTree.parse(data)
        var result = EPUBNavigationDocument()

        for navigation in root.descendants(named: "nav") {
            let types = navigation.attribute(named: "epub:type")
                .map(tokens) ?? []
            let kind: NavigationKind?
            if types.contains("toc") {
                kind = .tableOfContents
            } else if types.contains("landmarks") {
                kind = .landmarks
            } else if types.contains("page-list") {
                kind = .pageList
            } else {
                kind = nil
            }

            guard let kind,
                  let list = navigation.children.first(where: { $0.localName == "ol" })
                    ?? navigation.descendants(named: "ol").first
            else {
                continue
            }

            let nodes = parseHTMLList(
                list,
                kind: kind,
                documentHref: documentHref,
                path: []
            )
            switch kind {
            case .tableOfContents where result.tableOfContents.isEmpty:
                result.tableOfContents = nodes
            case .landmarks where result.landmarks.isEmpty:
                result.landmarks = nodes
            case .pageList where result.pageList.isEmpty:
                result.pageList = nodes
            default:
                break
            }
        }

        return result
    }

    static func parseNCX(
        _ data: Data,
        documentHref: String
    ) throws -> EPUBNavigationDocument {
        let root = try XMLTree.parse(data)
        var result = EPUBNavigationDocument()

        if let navMap = root.descendants(named: "navMap").first {
            result.tableOfContents = navMap.children
                .filter { $0.localName == "navPoint" }
                .enumerated()
                .compactMap { index, node in
                    parseNCXPoint(
                        node,
                        kind: .tableOfContents,
                        documentHref: documentHref,
                        path: [index]
                    )
                }
        }

        if let pageList = root.descendants(named: "pageList").first {
            result.pageList = pageList.children
                .filter { $0.localName == "pageTarget" }
                .enumerated()
                .compactMap { index, node in
                    parseNCXPoint(
                        node,
                        kind: .pageList,
                        documentHref: documentHref,
                        path: [index]
                    )
                }
        }

        return result
    }

    private enum NavigationKind: String {
        case tableOfContents = "toc"
        case landmarks
        case pageList = "page-list"
    }

    private static func parseHTMLList(
        _ list: XMLTreeNode,
        kind: NavigationKind,
        documentHref: String,
        path: [Int]
    ) -> [TOCNode] {
        list.children
            .filter { $0.localName == "li" }
            .enumerated()
            .compactMap { index, item in
                let itemPath = path + [index]
                guard let labelElement = item.children.first(where: {
                    $0.localName == "a" || $0.localName == "span"
                }) else {
                    return nil
                }

                let rawHref = labelElement.attribute(named: "href") ?? ""
                let href = resolve(rawHref, relativeTo: documentHref)
                let title = labelElement.accessibleText.normalizedWhitespace()
                    .ifEmpty(labelElement.attribute(named: "title") ?? "Untitled")
                let roles = labelElement.attribute(named: "epub:type")
                    .map(tokens) ?? []
                let nested = item.children.first(where: { $0.localName == "ol" })
                let children = nested.map {
                    parseHTMLList(
                        $0,
                        kind: kind,
                        documentHref: documentHref,
                        path: itemPath
                    )
                } ?? []
                let id = item.attribute(named: "id")
                    ?? labelElement.attribute(named: "id")
                    ?? navigationID(kind: kind, path: itemPath, href: href)

                return TOCNode(
                    id: id,
                    title: title,
                    href: href,
                    roles: roles,
                    children: children
                )
            }
    }

    private static func parseNCXPoint(
        _ point: XMLTreeNode,
        kind: NavigationKind,
        documentHref: String,
        path: [Int]
    ) -> TOCNode? {
        let label = point.children.first(where: { $0.localName == "navLabel" })
        let content = point.children.first(where: { $0.localName == "content" })
        let rawHref = content?.attribute(named: "src") ?? ""
        let href = resolve(rawHref, relativeTo: documentHref)
        let title = label?.accessibleText.normalizedWhitespace().ifEmpty("Untitled") ?? "Untitled"
        let children = point.children
            .filter { $0.localName == "navPoint" }
            .enumerated()
            .compactMap { index, child in
                parseNCXPoint(
                    child,
                    kind: kind,
                    documentHref: documentHref,
                    path: path + [index]
                )
            }

        return TOCNode(
            id: point.attribute(named: "id")
                ?? navigationID(kind: kind, path: path, href: href),
            title: title,
            href: href,
            children: children
        )
    }

    private static func resolve(_ rawHref: String, relativeTo documentHref: String) -> String {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil {
            return trimmed
        }

        let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? ""
        let fragment = pieces.count > 1 ? String(pieces[1]) : nil
        let baseDirectory = (documentHref as NSString).deletingLastPathComponent
        let joined: String
        if rawPath.isEmpty {
            joined = documentHref
        } else if rawPath.hasPrefix("/") {
            joined = String(rawPath.drop(while: { $0 == "/" }))
        } else if baseDirectory.isEmpty {
            joined = rawPath
        } else {
            joined = (baseDirectory as NSString).appendingPathComponent(rawPath)
        }

        let normalized = normalizePath(joined.removingPercentEncoding ?? joined)
        if let fragment, !fragment.isEmpty {
            return "\(normalized)#\(fragment)"
        }
        return normalized
    }

    private static func normalizePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(String(component))
        }
        return components.joined(separator: "/")
    }

    private static func tokens(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func navigationID(kind: NavigationKind, path: [Int], href: String) -> String {
        let pathValue = path.map(String.init).joined(separator: ".")
        return "\(kind.rawValue)-\(pathValue)-\(href)"
    }
}

private final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLTreeNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    var accessibleText: String {
        let own = text
        let descendantText = children.map { child in
            if child.localName == "img" {
                return child.attribute(named: "alt")
                    ?? child.attribute(named: "title")
                    ?? ""
            }
            return child.accessibleText
        }.joined(separator: " ")
        return "\(own) \(descendantText)"
    }

    func attribute(named name: String) -> String? {
        if let value = attributes[name] {
            return value
        }
        let localName = name.split(separator: ":").last.map(String.init) ?? name
        return attributes.first(where: {
            ($0.key.split(separator: ":").last.map(String.init) ?? $0.key) == localName
        })?.value
    }

    func descendants(named name: String) -> [XMLTreeNode] {
        children.flatMap { child in
            (child.localName == name ? [child] : []) + child.descendants(named: name)
        }
    }
}

private enum XMLTree {
    static func parse(_ data: Data) throws -> XMLTreeNode {
        let delegate = XMLTreeDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw BookError.malformedDocument(
                parser.parserError?.localizedDescription ?? "Unable to parse navigation XML"
            )
        }
        return root
    }
}

private final class XMLTreeDelegate: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    private var stack: [XMLTreeNode] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTreeNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
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

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
