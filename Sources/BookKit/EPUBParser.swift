import Foundation
import ZIPFoundation

public struct EPUBParser: BookParser {
    public let formats: Set<BookFormat> = [.epub]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try source.loadData(options: options)

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw BookError.invalidContainer("Unable to read EPUB zip archive")
        }

        var totalUncompressedBytes: UInt64 = 0
        for entry in archive where entry.type != .directory {
            guard entry.uncompressedSize <= UInt64(options.maxResourceBytes) else {
                throw BookError.invalidContainer(
                    "EPUB entry \(entry.path) exceeds the configured resource size limit"
                )
            }
            let (nextTotal, overflow) = totalUncompressedBytes.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !overflow,
                  nextTotal <= UInt64(options.maxArchiveUncompressedBytes)
            else {
                throw BookError.invalidContainer(
                    "EPUB archive exceeds the configured uncompressed size limit"
                )
            }
            totalUncompressedBytes = nextTotal
        }

        guard let containerData = try readEntry(at: "META-INF/container.xml", archive: archive) else {
            throw BookError.invalidContainer("Missing META-INF/container.xml")
        }

        let container = try ContainerDocument.parse(containerData)
        guard let opfPath = container.rootFilePath else {
            throw BookError.invalidContainer("Missing rootfile declaration in container.xml")
        }

        guard let opfData = try readEntry(at: opfPath, archive: archive) else {
            throw BookError.invalidContainer("Missing OPF package document at \(opfPath)")
        }

        let opf = try OPFDocument.parse(opfData)
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        var chapters: [Chapter] = []
        var diagnostics: [BookDiagnostic] = []

        let spineOrder = opf.spine.isEmpty ? opf.manifest.keys.sorted() : opf.spine
        var manifestByNormalizedHref: [String: OPFDocument.ManifestItem] = [:]
        for item in opf.manifest.values {
            manifestByNormalizedHref[normalizeRelativePath(item.href)] = item
        }
        let spineNormalizedHrefs = Set(
            spineOrder.compactMap { id in
                opf.manifest[id].map { normalizeRelativePath($0.href) }
            }
        )
        var publicationStylesByHref: [String: String] = [:]
        for item in opf.manifest.values where item.mediaType.lowercased() == "text/css" {
            let path = joinZipPath(base: opfDirectory, relative: item.href)
            guard let stylesheetData = try readEntry(at: path, archive: archive) else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "epub.missing-stylesheet",
                        message: "Missing stylesheet at \(path)",
                        location: path
                    )
                )
                continue
            }
            publicationStylesByHref[normalizeRelativePath(item.href)] = rewriteCSSReferences(
                in: stylesheetData.bestEffortString(),
                stylesheetHref: item.href,
                manifestByNormalizedHref: manifestByNormalizedHref
            )
        }

        for itemID in spineOrder {
            guard let item = opf.manifest[itemID] else {
                diagnostics.append(BookDiagnostic(severity: .warning, code: "epub.missing-spine-item", message: "Missing manifest item for spine id \(itemID)"))
                continue
            }

            guard item.mediaType.contains("html") || item.href.lowercased().hasSuffix(".xhtml") || item.href.lowercased().hasSuffix(".html") else {
                continue
            }

            let path = joinZipPath(base: opfDirectory, relative: item.href)
            guard let chapterData = try readEntry(at: path, archive: archive) else {
                diagnostics.append(BookDiagnostic(severity: .warning, code: "epub.missing-resource", message: "Missing chapter resource at \(path)"))
                continue
            }

            let html = chapterData.bestEffortString()
            let body = rewriteReferences(
                in: extractBodyContent(from: html),
                chapterHref: item.href,
                manifestByNormalizedHref: manifestByNormalizedHref,
                spineNormalizedHrefs: spineNormalizedHrefs
            )
            let linkedStyles = stylesheetHrefs(in: html).compactMap { rawHref -> String? in
                guard !hasScheme(rawHref) else { return nil }
                let resolved = resolveRelativePath(baseHref: item.href, relativePath: rawHref)
                return publicationStylesByHref[normalizeRelativePath(resolved)]
            }
            let inlineStyles = html.allMatches(for: "<style\\b[^>]*>(.*?)</style>")
            let publicationCSS = (linkedStyles + inlineStyles).joined(separator: "\n")
            let content = publicationCSS.isEmpty
                ? body
                : "<style data-bookkit-publication>\(publicationCSS)</style>\n\(body)"
            let title = html.firstMatch(for: "<title[^>]*>(.*?)</title>")
                ?? html.firstMatch(for: "<h1[^>]*>(.*?)</h1>")

            chapters.append(
                Chapter(id: item.id, href: item.href, title: title, content: content)
            )
        }

        if chapters.isEmpty {
            throw BookError.malformedDocument("EPUB contained no readable spine content")
        }

        let spineIDs = Set(spineOrder)
        var assets: [Asset] = []
        for item in opf.manifest.values.sorted(by: { $0.id < $1.id }) where !spineIDs.contains(item.id) {
            let path = joinZipPath(base: opfDirectory, relative: item.href)
            let payload = try readEntry(at: path, archive: archive)
            if payload == nil {
                diagnostics.append(BookDiagnostic(severity: .warning, code: "epub.missing-asset", message: "Missing asset at \(path)"))
            }
            assets.append(Asset(id: item.id, href: item.href, mediaType: item.mediaType, data: payload))
        }

        var navigation = EPUBNavigationDocument()
        if let navigationItem = opf.manifest.values.first(where: { $0.properties.contains("nav") }) {
            let path = joinZipPath(base: opfDirectory, relative: navigationItem.href)
            if let data = try readEntry(at: path, archive: archive) {
                do {
                    navigation = try EPUBNavigationParser.parseNavigationDocument(
                        data,
                        documentHref: navigationItem.href
                    )
                } catch {
                    diagnostics.append(
                        BookDiagnostic(
                            severity: .warning,
                            code: "epub.invalid-navigation-document",
                            message: String(describing: error),
                            location: path
                        )
                    )
                }
            }
        }

        if navigation.tableOfContents.isEmpty,
           let ncxItem = opf.spineTOCID.flatMap({ opf.manifest[$0] })
            ?? opf.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        {
            let path = joinZipPath(base: opfDirectory, relative: ncxItem.href)
            if let data = try readEntry(at: path, archive: archive) {
                do {
                    let ncx = try EPUBNavigationParser.parseNCX(
                        data,
                        documentHref: ncxItem.href
                    )
                    navigation.tableOfContents = ncx.tableOfContents
                    if navigation.pageList.isEmpty {
                        navigation.pageList = ncx.pageList
                    }
                } catch {
                    diagnostics.append(
                        BookDiagnostic(
                            severity: .warning,
                            code: "epub.invalid-ncx",
                            message: String(describing: error),
                            location: path
                        )
                    )
                }
            }
        }

        let toc = navigation.tableOfContents.isEmpty
            ? chapters.map { chapter in
                TOCNode(title: chapter.title ?? chapter.id, href: chapter.href)
            }
            : navigation.tableOfContents

        let metadata = Metadata(
            title: opf.title ?? chapters.first?.title ?? "Untitled",
            authors: opf.creators,
            language: opf.language,
            identifiers: opf.identifier.map { ["primary": $0] } ?? [:],
            publisher: opf.publisher,
            publicationDate: opf.modifiedDate
        )

        return Book(
            id: opf.identifier ?? DeterministicIdentifier.make(namespace: "epub", data: data),
            format: .epub,
            version: opf.version ?? "3.0",
            metadata: metadata,
            readingOrder: chapters,
            assets: assets,
            tableOfContents: toc,
            landmarks: navigation.landmarks,
            pageList: navigation.pageList,
            rawExtensions: [:],
            diagnostics: diagnostics
        )
    }

    private func readEntry(at path: String, archive: Archive) throws -> Data? {
        let normalized = normalizeZipPath(path)
        let candidates = [normalized, normalized.removingPercentEncoding ?? normalized, String(normalized.drop(while: { $0 == "/" }))]

        for candidate in candidates {
            guard let entry = archive[candidate] else {
                continue
            }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            return data
        }
        return nil
    }

    private func normalizeZipPath(_ path: String) -> String {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []

        for component in replaced.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                if !parts.isEmpty {
                    parts.removeLast()
                }
                continue
            }
            parts.append(String(component))
        }

        return parts.joined(separator: "/")
    }

    private func normalizeRelativePath(_ path: String) -> String {
        let noFragment = path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let noQuery = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? noFragment
        let decoded = noQuery.removingPercentEncoding ?? noQuery
        return normalizeZipPath(decoded)
    }

    private func joinZipPath(base: String, relative: String) -> String {
        let rel = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard !base.isEmpty else { return rel }
        return normalizeZipPath((base as NSString).appendingPathComponent(rel))
    }

    private func extractBodyContent(from html: String) -> String {
        let pattern = "<body\\b[^>]*>(.*?)</body>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..<html.endIndex, in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else {
            return html
        }

        return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteReferences(
        in html: String,
        chapterHref: String,
        manifestByNormalizedHref: [String: OPFDocument.ManifestItem],
        spineNormalizedHrefs: Set<String>
    ) -> String {
        let pattern = "(?i)(href|src|poster|srcset)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return html
        }

        var output = html
        let matches = regex.matches(in: output, options: [], range: NSRange(output.startIndex..<output.endIndex, in: output))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let attrRange = Range(match.range(at: 1), in: output)
            else {
                continue
            }

            let quote: String
            let rawValue: String
            if let valueRange = Range(match.range(at: 3), in: output) {
                quote = "\""
                rawValue = String(output[valueRange])
            } else if let valueRange = Range(match.range(at: 4), in: output) {
                quote = "'"
                rawValue = String(output[valueRange])
            } else {
                continue
            }

            let attr = String(output[attrRange])
            let rewritten = rewriteReferenceValue(
                rawValue,
                attribute: attr,
                chapterHref: chapterHref,
                manifestByNormalizedHref: manifestByNormalizedHref,
                spineNormalizedHrefs: spineNormalizedHrefs
            )

            if rewritten == rawValue {
                continue
            }

            output.replaceSubrange(fullRange, with: "\(attr)=\(quote)\(rewritten)\(quote)")
        }

        return output
    }

    private func rewriteReferenceValue(
        _ rawValue: String,
        attribute: String,
        chapterHref: String,
        manifestByNormalizedHref: [String: OPFDocument.ManifestItem],
        spineNormalizedHrefs: Set<String>
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if attribute.lowercased() == "srcset" {
            return trimmed.split(separator: ",", omittingEmptySubsequences: true)
                .map { candidate in
                    let parts = candidate.split(whereSeparator: { $0.isWhitespace })
                    guard let source = parts.first else { return String(candidate) }
                    let descriptor = parts.dropFirst().joined(separator: " ")
                    let rewritten = rewriteReferenceValue(
                        String(source),
                        attribute: "src",
                        chapterHref: chapterHref,
                        manifestByNormalizedHref: manifestByNormalizedHref,
                        spineNormalizedHrefs: spineNormalizedHrefs
                    )
                    return descriptor.isEmpty ? rewritten : "\(rewritten) \(descriptor)"
                }
                .joined(separator: ", ")
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") || hasScheme(trimmed) {
            return rawValue
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? trimmed
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let resolvedPath = resolveRelativePath(baseHref: chapterHref, relativePath: rawPath)
        let normalizedPath = normalizeRelativePath(resolvedPath)
        guard !normalizedPath.isEmpty,
              let manifestItem = manifestByNormalizedHref[normalizedPath]
        else {
            return rawValue
        }

        let lowerAttr = attribute.lowercased()
        if spineNormalizedHrefs.contains(normalizedPath) {
            guard lowerAttr == "href" else {
                return rawValue
            }

            if let fragment, !fragment.isEmpty {
                return "\(normalizedPath)#\(fragment)"
            }
            return normalizedPath
        }

        if lowerAttr == "href" || lowerAttr == "src" || lowerAttr == "poster" {
            return "bookkit://asset/\(manifestItem.id)"
        }

        return rawValue
    }

    private func resolveRelativePath(baseHref: String, relativePath: String) -> String {
        if relativePath.hasPrefix("/") {
            return String(relativePath.dropFirst())
        }

        let baseDirectory = (baseHref as NSString).deletingLastPathComponent
        if baseDirectory.isEmpty {
            return relativePath
        }

        return (baseDirectory as NSString).appendingPathComponent(relativePath)
    }

    private func hasScheme(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
    }

    private func stylesheetHrefs(in html: String) -> [String] {
        html.allMatches(for: "(<link\\b[^>]*>)").compactMap { tag in
            guard let rel = tag.firstMatch(for: "\\brel\\s*=\\s*['\"]([^'\"]+)['\"]"),
                  rel.lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet")
            else {
                return nil
            }
            return tag.firstMatch(for: "\\bhref\\s*=\\s*['\"]([^'\"]+)['\"]")
        }
    }

    private func rewriteCSSReferences(
        in css: String,
        stylesheetHref: String,
        manifestByNormalizedHref: [String: OPFDocument.ManifestItem]
    ) -> String {
        let pattern = "(?i)url\\(\\s*(['\"]?)([^)'\"]+)\\1\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return css
        }

        var output = css
        let matches = regex.matches(
            in: output,
            range: NSRange(output.startIndex..<output.endIndex, in: output)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 2), in: output)
            else {
                continue
            }
            let rawValue = String(output[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty,
                  !rawValue.hasPrefix("#"),
                  !rawValue.lowercased().hasPrefix("data:"),
                  !hasScheme(rawValue)
            else {
                continue
            }
            let resolved = resolveRelativePath(baseHref: stylesheetHref, relativePath: rawValue)
            guard let item = manifestByNormalizedHref[normalizeRelativePath(resolved)] else {
                continue
            }
            output.replaceSubrange(fullRange, with: "url(\"bookkit://asset/\(item.id)\")")
        }
        return output
    }
}

private struct ContainerDocument {
    var rootFilePath: String?

    static func parse(_ data: Data) throws -> ContainerDocument {
        let delegate = ContainerXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse() {
            return ContainerDocument(rootFilePath: delegate.rootFilePath)
        }
        throw BookError.malformedDocument("Failed to parse container.xml")
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var rootFilePath: String?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "rootfile", let path = attributeDict["full-path"] {
            rootFilePath = path
        }
    }
}

private struct OPFDocument {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>
    }

    var version: String?
    var title: String?
    var creators: [String]
    var language: String?
    var publisher: String?
    var identifier: String?
    var modifiedDate: String?
    var manifest: [String: ManifestItem]
    var spine: [String]
    var spineTOCID: String?

    static func parse(_ data: Data) throws -> OPFDocument {
        let delegate = OPFXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse() {
            return OPFDocument(
                version: delegate.version,
                title: delegate.title,
                creators: delegate.creators,
                language: delegate.language,
                publisher: delegate.publisher,
                identifier: delegate.identifier,
                modifiedDate: delegate.modifiedDate,
                manifest: delegate.manifest,
                spine: delegate.spine,
                spineTOCID: delegate.spineTOCID
            )
        }
        throw BookError.malformedDocument("Failed to parse OPF package")
    }
}

private final class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var version: String?
    var title: String?
    var creators: [String] = []
    var language: String?
    var publisher: String?
    var identifier: String?
    var modifiedDate: String?
    var manifest: [String: OPFDocument.ManifestItem] = [:]
    var spine: [String] = []
    var spineTOCID: String?

    private var elementStack: [String] = []
    private var currentText = ""

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)
        elementStack.append(local)
        currentText = ""

        if local == "package" {
            version = attributeDict["version"]
        }

        if local == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"]
        {
            let mediaType = attributeDict["media-type"] ?? "application/octet-stream"
            let properties = Set(
                (attributeDict["properties"] ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )
            manifest[id] = OPFDocument.ManifestItem(
                id: id,
                href: href,
                mediaType: mediaType,
                properties: properties
            )
        }

        if local == "spine" {
            spineTOCID = attributeDict["toc"]
        }

        if local == "itemref", let idref = attributeDict["idref"] {
            spine.append(idref)
        }

        if local == "meta",
           attributeDict["property"] == "dcterms:modified",
           let content = attributeDict["content"]
        {
            modifiedDate = content
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let local = localName(elementName)
        let value = currentText.normalizedWhitespace()

        if !value.isEmpty {
            switch local {
            case "title":
                if title == nil { title = value }
            case "creator":
                creators.append(value)
            case "language":
                if language == nil { language = value }
            case "publisher":
                if publisher == nil { publisher = value }
            case "identifier":
                if identifier == nil { identifier = value }
            case "date":
                if modifiedDate == nil { modifiedDate = value }
            default:
                break
            }
        }

        _ = elementStack.popLast()
        currentText = ""
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
