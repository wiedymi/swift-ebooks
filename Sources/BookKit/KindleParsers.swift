import Foundation

public struct MOBIParser: BookParser {
    public let formats: Set<BookFormat> = [.mobi]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        try KindlePublication.parse(source: source, options: options, format: .mobi)
    }
}

public struct AZW3Parser: BookParser {
    public let formats: Set<BookFormat> = [.azw3]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        try KindlePublication.parse(source: source, options: options, format: .azw3)
    }
}

private enum KindlePublication {
    static func parse(source: BookSource, options: OpenOptions, format: BookFormat) throws -> Book {
        let data = try source.loadData(options: options)
        let container = try PalmContainer(data: data)
        let header = try KindleHeader(record: container.records[0])
        guard header.encryption == 0 else {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .kindleDRM,
                    scheme: "PalmDOC encryption \(header.encryption)"
                )
            )
        }

        let exth = EXTHMetadata.parse(record: container.records[0], header: header)
        let textData = try decompressText(container: container, header: header)
        let title = exth.title?.normalizedWhitespace().nonEmpty
            ?? header.fullName?.normalizedWhitespace().nonEmpty
            ?? container.databaseName.normalizedWhitespace().nonEmpty
            ?? source.fileName
            ?? "Untitled"
        let authors = exth.authors.map { $0.normalizedWhitespace() }.filter { !$0.isEmpty }
        let assets = extractAssets(container: container, firstImageIndex: header.firstImageIndex)
        let identifier = exth.asin?.nonEmpty
            ?? DeterministicIdentifier.make(namespace: format.rawValue, data: data)

        let parsed: ParsedKindleContent
        if header.version >= 8, let flows = flowRanges(container: container, textLength: textData.count) {
            parsed = parseKF8(
                textData: textData,
                flows: flows,
                title: title,
                assets: assets
            )
        } else {
            parsed = parseMOBI6(
                textData: textData,
                title: title,
                assets: assets
            )
        }

        guard !parsed.chapters.isEmpty else {
            throw BookError.malformedDocument("No readable Kindle content was extracted")
        }

        var identifiers: [String: String] = [:]
        if let asin = exth.asin?.nonEmpty {
            identifiers["asin"] = asin
        }
        if let isbn = exth.isbn?.nonEmpty {
            identifiers["isbn"] = isbn
        }

        var diagnostics = parsed.diagnostics
        if header.compression == 17_480 {
            diagnostics.append(
                BookDiagnostic(
                    severity: .warning,
                    code: "kindle.huffdic",
                    message: "HUFF/CDIC content was not decoded"
                )
            )
        }

        return Book(
            id: identifier,
            format: format,
            version: String(header.version),
            metadata: Metadata(
                title: title,
                authors: authors,
                language: exth.language,
                identifiers: identifiers,
                publisher: exth.publisher,
                publicationDate: exth.publicationDate
            ),
            readingOrder: parsed.chapters,
            assets: assets.map(\.asset),
            tableOfContents: parsed.tableOfContents,
            landmarks: parsed.landmarks,
            pageList: [],
            rawExtensions: ["bookkit:kindle-rendering": parsed.renderingKind],
            diagnostics: diagnostics
        )
    }

    private static func decompressText(
        container: PalmContainer,
        header: KindleHeader
    ) throws -> Data {
        guard header.textRecordCount > 0,
              header.textRecordCount < container.records.count
        else {
            throw BookError.malformedDocument("Invalid Kindle text record count")
        }

        guard header.compression == 1 || header.compression == 2 else {
            throw BookError.malformedDocument(
                "Unsupported Kindle compression \(header.compression); only uncompressed and PalmDOC are supported"
            )
        }

        var output = Data()
        output.reserveCapacity(header.textLength)
        for index in 1...header.textRecordCount {
            let record = stripTrailingData(
                container.records[index],
                flags: header.extraDataFlags
            )
            if header.compression == 1 {
                output.append(record)
            } else {
                output.append(try PalmDOC.decompress(record))
            }
        }
        if output.count > header.textLength {
            output.removeSubrange(header.textLength..<output.count)
        }
        return output
    }

    private static func stripTrailingData(_ data: Data, flags: Int) -> Data {
        guard !data.isEmpty, flags != 0 else { return data }
        let bytes = [UInt8](data)
        var end = bytes.count
        var flagBits = flags >> 1
        while flagBits > 0, end > 0 {
            if flagBits & 1 == 1 {
                let size = trailingEntrySize(bytes, end: end)
                end = max(0, end - min(size, end))
            }
            flagBits >>= 1
        }
        if flags & 1 == 1, end > 0 {
            end = max(0, end - min(Int(bytes[end - 1] & 0x03) + 1, end))
        }
        return Data(bytes[..<end])
    }

    private static func trailingEntrySize(_ bytes: [UInt8], end: Int) -> Int {
        var value = 0
        for distance in 1...min(4, end) {
            let byte = bytes[end - distance]
            value = (value << 7) | Int(byte & 0x7f)
            if byte & 0x80 != 0 {
                return value
            }
        }
        return 0
    }

    private static func extractAssets(
        container: PalmContainer,
        firstImageIndex: Int?
    ) -> [KindleAsset] {
        guard let firstImageIndex,
              container.records.indices.contains(firstImageIndex)
        else {
            return []
        }

        return container.records[firstImageIndex...].enumerated().compactMap { offset, data in
            guard let mediaType = imageMediaType(data) else { return nil }
            let number = offset + 1
            return KindleAsset(
                number: number,
                asset: Asset(
                    id: "kindle-image-\(number)",
                    href: "kindle/images/image-\(number).\(fileExtension(for: mediaType))",
                    mediaType: mediaType,
                    data: data
                )
            )
        }
    }

    private static func imageMediaType(_ data: Data) -> String? {
        if data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
            return "image/png"
        }
        if data.starts(with: Data([0xff, 0xd8, 0xff])) {
            return "image/jpeg"
        }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return "image/gif"
        }
        return nil
    }

    private static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": return "png"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }

    private static func flowRanges(
        container: PalmContainer,
        textLength: Int
    ) -> [Range<Int>]? {
        guard let fdst = container.records.first(where: { $0.starts(with: Data("FDST".utf8)) }),
              let count = fdst.uint32BE(at: 8),
              count > 0,
              count < 1_024
        else {
            return nil
        }

        var ranges: [Range<Int>] = []
        for index in 0..<count {
            let offset = 12 + index * 8
            guard let start = fdst.uint32BE(at: offset),
                  let end = fdst.uint32BE(at: offset + 4),
                  start >= 0,
                  end >= start,
                  end <= textLength
            else {
                return nil
            }
            ranges.append(start..<end)
        }
        return ranges
    }

    private static func parseMOBI6(
        textData: Data,
        title: String,
        assets: [KindleAsset]
    ) -> ParsedKindleContent {
        let targets = filePositionTargets(in: textData)
        var anchoredData = textData
        for target in targets.sorted(by: >) where target <= anchoredData.count {
            anchoredData.insert(
                contentsOf: Data("<a id=\"filepos\(target)\"></a>".utf8),
                at: target
            )
        }

        var html = decode(anchoredData)
        let guide = guideReferences(in: html)
        html = rewriteFilePositionAttributes(in: html)
        html = rewriteKindleResources(in: html, assets: assets)
        html = html.replacingOccurrences(
            of: "(?i)<\\s*(?:mbp:)?pagebreak\\b[^>]*>",
            with: "<hr class=\"bookkit-page-break\">",
            options: .regularExpression
        )
        html = bodyContent(in: html)
        html = """
        <style data-bookkit-publication>
        blockquote { margin-block: 0; margin-inline: 1em 0; }
        .bookkit-page-break { break-before: page; border: 0; margin: 2em 0; }
        </style>
        \(html)
        """

        let href = "kindle/content.xhtml"
        let tocOffset = guide.first(where: { $0.roles.contains("toc") })?.filePosition
        var toc = tocOffset.map {
            tocLinks(in: textData, startingAt: $0, chapterHref: href)
        } ?? []
        if toc.isEmpty {
            toc = [TOCNode(title: title, href: href)]
        }
        let landmarks = guide.map { item in
            TOCNode(
                id: "kindle-guide-\(item.filePosition)",
                title: item.title,
                href: "\(href)#filepos\(item.filePosition)",
                roles: item.roles
            )
        }

        return ParsedKindleContent(
            chapters: [Chapter(id: "kindle-content", href: href, title: title, content: html)],
            tableOfContents: toc,
            landmarks: landmarks,
            diagnostics: [],
            renderingKind: "mobi6-palmdoc"
        )
    }

    private static func parseKF8(
        textData: Data,
        flows: [Range<Int>],
        title: String,
        assets: [KindleAsset]
    ) -> ParsedKindleContent {
        let mainFlow = flows.first.map { Data(textData[$0]) } ?? textData
        let css = flows.dropFirst().map { range in
            rewriteKindleResources(in: decode(Data(textData[range])), assets: assets)
        }.joined(separator: "\n")
        let style = css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "<style data-bookkit-publication>\(css)</style>\n"

        let rawMain = decode(mainFlow)
        let segments = splitXMLDocuments(rawMain)
        var chapters: [Chapter] = []
        for (index, segment) in segments.enumerated() {
            let chapterTitle = segment.firstMatch(for: "<title[^>]*>(.*?)</title>")
                ?? segment.firstMatch(for: "<h[1-3][^>]*>(.*?)</h[1-3]>")
                ?? "Chapter \(index + 1)"
            var content = segment.replacingOccurrences(
                of: "(?is)<head\\b[^>]*>.*?</head>",
                with: "",
                options: .regularExpression
            )
            content = content.replacingOccurrences(
                of: "(?i)<\\?xml[^>]*>|<\\/?html\\b[^>]*>|<\\/?body\\b[^>]*>",
                with: "",
                options: .regularExpression
            )
            content = rewriteKindleResources(in: content, assets: assets)
            guard !content.strippingHTML().normalizedWhitespace().isEmpty
                    || content.contains("<img")
            else {
                continue
            }
            let chapterNumber = chapters.count + 1
            chapters.append(
                Chapter(
                    id: "kf8-\(chapterNumber)",
                    href: "kindle/chapter-\(chapterNumber).xhtml",
                    title: chapterTitle,
                    content: style + content
                )
            )
        }

        if chapters.isEmpty {
            let content = style + rewriteKindleResources(in: rawMain, assets: assets)
            chapters = [
                Chapter(id: "kf8-1", href: "kindle/chapter-1.xhtml", title: title, content: content),
            ]
        }

        let toc = chapters.map { chapter in
            TOCNode(title: chapter.title ?? chapter.id, href: chapter.href)
        }
        return ParsedKindleContent(
            chapters: chapters,
            tableOfContents: toc,
            landmarks: [],
            diagnostics: [
                BookDiagnostic(
                    severity: .info,
                    code: "kindle.kf8-best-effort-navigation",
                    message: "KF8 content and resource flows were decoded; proprietary NCX position indexes remain best-effort"
                ),
            ],
            renderingKind: "kf8-fdst"
        )
    }

    private static func splitXMLDocuments(_ input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?i)<\\?xml\\b") else {
            return [input]
        }
        let matches = regex.matches(
            in: input,
            range: NSRange(input.startIndex..<input.endIndex, in: input)
        )
        guard matches.count > 1 else { return [input] }
        return matches.enumerated().compactMap { index, match in
            guard let start = Range(match.range, in: input)?.lowerBound else { return nil }
            let end: String.Index
            if index + 1 < matches.count,
               let next = Range(matches[index + 1].range, in: input)?.lowerBound
            {
                end = next
            } else {
                end = input.endIndex
            }
            return String(input[start..<end])
        }
    }

    private static func bodyContent(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<body\\b[^>]*>(.*?)</body>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let match = regex.firstMatch(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html)
        ),
        let range = Range(match.range(at: 1), in: html)
        else {
            return html
        }
        return String(html[range])
    }

    private static func filePositionTargets(in data: Data) -> Set<Int> {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)\\bfilepos\\s*=\\s*['\"]?(\\d+)"
        ) else {
            return []
        }
        return Set(regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        })
    }

    private static func rewriteFilePositionAttributes(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)\\bfilepos\\s*=\\s*['\"]?0*(\\d+)['\"]?"
        ) else {
            return html
        }
        var output = html
        for match in regex.matches(
            in: output,
            range: NSRange(output.startIndex..<output.endIndex, in: output)
        ).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 1), in: output)
            else { continue }
            let value = String(output[valueRange])
            output.replaceSubrange(fullRange, with: "href=\"#filepos\(value)\"")
        }
        return output
    }

    private static func guideReferences(in html: String) -> [GuideReference] {
        let tags = html.allMatches(for: "(<reference\\b[^>]*>)")
        return tags.compactMap { tag in
            guard let rawPosition = tag.firstMatch(
                for: "\\bfilepos\\s*=\\s*['\"]?(\\d+)"
            ), let position = Int(rawPosition) else {
                return nil
            }
            let title = tag.firstMatch(for: "\\btitle\\s*=\\s*['\"]([^'\"]+)['\"]")
                ?? "Landmark"
            let roles = tag.firstMatch(for: "\\btype\\s*=\\s*['\"]([^'\"]+)['\"]")?
                .split(whereSeparator: \.isWhitespace)
                .map(String.init) ?? []
            return GuideReference(title: title, roles: roles, filePosition: position)
        }
    }

    private static func tocLinks(
        in data: Data,
        startingAt offset: Int,
        chapterHref: String
    ) -> [TOCNode] {
        guard data.indices.contains(offset) else { return [] }
        let tail = data[offset...]
        let pageBreak = Data("<mbp:pagebreak".utf8)
        let end = tail.range(of: pageBreak)?.lowerBound ?? data.endIndex
        let chunk = decode(Data(data[offset..<end]))
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<a\\b[^>]*filepos\\s*=\\s*['\"]?(\\d+)['\"]?[^>]*>(.*?)</a>"
        ) else {
            return []
        }
        var seen: Set<String> = []
        return regex.matches(
            in: chunk,
            range: NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
        ).compactMap { match in
            guard let positionRange = Range(match.range(at: 1), in: chunk),
                  let labelRange = Range(match.range(at: 2), in: chunk)
            else { return nil }
            let position = String(chunk[positionRange]).drop(while: { $0 == "0" })
            let normalizedPosition = position.isEmpty ? "0" : String(position)
            let label = String(chunk[labelRange]).strippingHTML().normalizedWhitespace()
            guard !label.isEmpty else { return nil }
            let key = "\(normalizedPosition)|\(label)"
            guard seen.insert(key).inserted else { return nil }
            return TOCNode(
                title: label,
                href: "\(chapterHref)#filepos\(normalizedPosition)"
            )
        }
    }

    private static func rewriteKindleResources(
        in input: String,
        assets: [KindleAsset]
    ) -> String {
        let available = Set(assets.map(\.number))
        var output = input
        if let regex = try? NSRegularExpression(
            pattern: "(?i)kindle:embed:([0-9a-v]+)(?:\\?mime=[^'\" )]+)?"
        ) {
            for match in regex.matches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            ).reversed() {
                guard let fullRange = Range(match.range(at: 0), in: output),
                      let valueRange = Range(match.range(at: 1), in: output)
                else { continue }
                let number = parseBase32(String(output[valueRange]))
                guard available.contains(number) else { continue }
                output.replaceSubrange(fullRange, with: "bookkit://asset/kindle-image-\(number)")
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "(?i)<img\\b[^>]*\\brecindex\\s*=\\s*['\"]?0*(\\d+)['\"]?[^>]*>"
        ) {
            for match in regex.matches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            ).reversed() {
                guard let tagRange = Range(match.range(at: 0), in: output),
                      let valueRange = Range(match.range(at: 1), in: output),
                      let number = Int(output[valueRange]),
                      available.contains(number)
                else { continue }
                var tag = String(output[tagRange])
                if tag.range(of: "\\bsrc\\s*=", options: [.regularExpression, .caseInsensitive]) == nil {
                    let insertion = " src=\"bookkit://asset/kindle-image-\(number)\">"
                    tag = String(tag.dropLast()) + insertion
                }
                output.replaceSubrange(tagRange, with: tag)
            }
        }
        return output
    }

    private static func parseBase32(_ value: String) -> Int {
        value.uppercased().utf8.reduce(0) { result, byte in
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...86: digit = Int(byte - 65) + 10
            default: return result
            }
            return result &* 32 &+ digit
        }
    }

    fileprivate static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }
}

private struct ParsedKindleContent {
    var chapters: [Chapter]
    var tableOfContents: [TOCNode]
    var landmarks: [TOCNode]
    var diagnostics: [BookDiagnostic]
    var renderingKind: String
}

private struct KindleAsset {
    var number: Int
    var asset: Asset
}

private struct GuideReference {
    var title: String
    var roles: [String]
    var filePosition: Int
}

private struct PalmContainer {
    let databaseName: String
    let records: [Data]

    init(data: Data) throws {
        guard data.count >= 78,
              let recordCount = data.uint16BE(at: 76),
              recordCount > 0,
              78 + recordCount * 8 <= data.count
        else {
            throw BookError.invalidContainer("Invalid Palm database header")
        }
        let signature = String(data: data[60..<68], encoding: .ascii) ?? ""
        guard signature == "BOOKMOBI" else {
            throw BookError.invalidContainer("Palm database is not a MOBI publication")
        }

        let rawName = data.prefix(32).prefix(while: { $0 != 0 })
        databaseName = String(data: rawName, encoding: .utf8)
            ?? String(data: rawName, encoding: .isoLatin1)
            ?? "Untitled"

        var offsets: [Int] = []
        offsets.reserveCapacity(recordCount + 1)
        for index in 0..<recordCount {
            guard let offset = data.uint32BE(at: 78 + index * 8),
                  offset >= 0,
                  offset <= data.count,
                  offset >= (offsets.last ?? 0)
            else {
                throw BookError.invalidContainer("Invalid Palm record offset")
            }
            offsets.append(offset)
        }
        offsets.append(data.count)
        records = (0..<recordCount).map { index in
            Data(data[offsets[index]..<offsets[index + 1]])
        }
    }
}

private struct KindleHeader {
    let compression: Int
    let textLength: Int
    let textRecordCount: Int
    let encryption: Int
    let headerLength: Int
    let encoding: Int
    let version: Int
    let fullName: String?
    let firstImageIndex: Int?
    let extraDataFlags: Int

    init(record: Data) throws {
        guard record.count >= 24,
              record[16..<20] == Data("MOBI".utf8),
              let compression = record.uint16BE(at: 0),
              let textLength = record.uint32BE(at: 4),
              let textRecordCount = record.uint16BE(at: 8),
              let encryption = record.uint16BE(at: 12),
              let headerLength = record.uint32BE(at: 20),
              let encoding = record.uint32BE(at: 28),
              let version = record.uint32BE(at: 36)
        else {
            throw BookError.invalidContainer("Invalid MOBI header")
        }
        self.compression = compression
        self.textLength = textLength
        self.textRecordCount = textRecordCount
        self.encryption = encryption
        self.headerLength = headerLength
        self.encoding = encoding
        self.version = version
        firstImageIndex = record.uint32BE(at: 108).flatMap { $0 == Int(UInt32.max) ? nil : $0 }
        extraDataFlags = record.uint16BE(at: 242) ?? 0

        if let offset = record.uint32BE(at: 84),
           let length = record.uint32BE(at: 88),
           offset >= 0,
           length > 0,
           offset + length <= record.count
        {
            let data = Data(record[offset..<(offset + length)])
            fullName = KindlePublication.decode(data)
        } else {
            fullName = nil
        }
    }
}

private struct EXTHMetadata {
    var title: String?
    var authors: [String] = []
    var publisher: String?
    var publicationDate: String?
    var isbn: String?
    var asin: String?
    var language: String?

    static func parse(record: Data, header: KindleHeader) -> EXTHMetadata {
        let start = 16 + header.headerLength
        guard start + 12 <= record.count,
              record[start..<(start + 4)] == Data("EXTH".utf8),
              let totalLength = record.uint32BE(at: start + 4),
              let count = record.uint32BE(at: start + 8),
              start + totalLength <= record.count,
              count < 10_000
        else {
            return EXTHMetadata()
        }

        var result = EXTHMetadata()
        var offset = start + 12
        for _ in 0..<count {
            guard let type = record.uint32BE(at: offset),
                  let length = record.uint32BE(at: offset + 4),
                  length >= 8,
                  offset + length <= start + totalLength
            else {
                break
            }
            let payload = Data(record[(offset + 8)..<(offset + length)])
            let value = KindlePublication.decode(payload)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            switch type {
            case 100: result.authors.append(value)
            case 101: result.publisher = value
            case 104: result.isbn = value
            case 106: result.publicationDate = value
            case 113: result.asin = value
            case 503: result.title = value
            case 524: result.language = value
            default: break
            }
            offset += length
        }
        return result
    }
}

private enum PalmDOC {
    static func decompress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var index = 0

        while index < input.count {
            let byte = input[index]
            index += 1
            switch byte {
            case 0:
                output.append(0)
            case 1...8:
                let count = min(Int(byte), input.count - index)
                output.append(contentsOf: input[index..<(index + count)])
                index += count
            case 9...0x7f:
                output.append(byte)
            case 0x80...0xbf:
                guard index < input.count else {
                    throw BookError.malformedDocument("Truncated PalmDOC back-reference")
                }
                let pair = (Int(byte) << 8) | Int(input[index])
                index += 1
                let distance = (pair >> 3) & 0x07ff
                let length = (pair & 0x07) + 3
                guard distance > 0, distance <= output.count else {
                    throw BookError.malformedDocument("Invalid PalmDOC back-reference")
                }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
            }
        }
        return Data(output)
    }
}

private extension Data {
    func uint16BE(at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return self[offset..<(offset + 2)].reduce(0) { ($0 << 8) | Int($1) }
    }

    func uint32BE(at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
