import Foundation

struct CBZParser: BookParser {
    public let formats: Set<BookFormat> = [.cbz]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try await source.loadData(options: options)
        let container = try SafeZIPArchive(data: data, options: options, kind: "CBZ")
        let imagePaths = container.files.map(\.path)
            .filter(Self.isImagePath)
            .filter { !Self.isIgnoredPath($0) }
            .sorted(by: Self.naturalOrder)

        guard !imagePaths.isEmpty else {
            throw BookError.malformedDocument("CBZ archive contains no supported images")
        }

        let comicInfoPath = container.files.map(\.path).first {
            ($0 as NSString).lastPathComponent.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame
        }
        var diagnostics: [BookDiagnostic] = []
        let comicInfo: ComicInfo
        if let comicInfoPath, let comicInfoData = try container.data(at: comicInfoPath) {
            do {
                comicInfo = try ComicInfo.parse(comicInfoData)
            } catch {
                comicInfo = ComicInfo()
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "cbz.invalid-comicinfo",
                        message: String(describing: error),
                        location: comicInfoPath
                    )
                )
            }
        } else {
            comicInfo = ComicInfo()
        }

        let progression: ReadingProgression = comicInfo.manga.caseInsensitiveCompare(
            "YesAndRightToLeft"
        ) == .orderedSame ? .rightToLeft : .leftToRight
        let explicitCoverIndex = comicInfo.pages.first(where: {
            $0.types.contains(where: { $0.caseInsensitiveCompare("FrontCover") == .orderedSame })
        })?.imageIndex
        let namedCoverIndex = imagePaths.firstIndex {
            let stem = (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
            return stem.range(of: "cover", options: .caseInsensitive) != nil
        }
        let coverIndex = [explicitCoverIndex, namedCoverIndex, 0]
            .compactMap { $0 }
            .first(where: imagePaths.indices.contains) ?? 0

        var assets: [Asset] = []
        var chapters: [Chapter] = []
        var pageList: [TOCNode] = []
        var tableOfContents: [TOCNode] = []

        for (index, path) in imagePaths.enumerated() {
            guard let payload = try container.data(at: path) else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "cbz.missing-page",
                        message: "Unable to extract image page",
                        location: path
                    )
                )
                continue
            }
            let id = "cbz-page-\(index + 1)"
            let mediaType = Self.mediaType(for: path)
            let info = comicInfo.pages.first { $0.imageIndex == index }
            let isCover = index == coverIndex
            let isSpread = info?.isDoublePage ?? false
            let side = Self.pageSide(
                index: index,
                coverIndex: coverIndex,
                progression: progression,
                isSpread: isSpread
            )
            let title = info?.bookmark.nonEmpty
                ?? (isCover ? "Cover" : "Page \(index + 1)")

            assets.append(Asset(id: id, href: path, mediaType: mediaType, data: payload))
            chapters.append(
                Chapter(
                    id: id,
                    href: path,
                    title: title,
                    content: "",
                    resourceID: id,
                    mediaType: mediaType,
                    page: PagePresentation(
                        side: side,
                        isCover: isCover,
                        isSpread: isSpread,
                        pixelWidth: info?.imageWidth,
                        pixelHeight: info?.imageHeight
                    )
                )
            )
            let navigation = TOCNode(
                id: "cbz-page-list-\(index + 1)",
                title: title,
                href: path,
                roles: isCover ? ["cover"] : []
            )
            pageList.append(navigation)
            if isCover || info?.bookmark.nonEmpty != nil {
                tableOfContents.append(navigation)
            }
        }

        guard !chapters.isEmpty else {
            throw BookError.malformedDocument("CBZ image pages could not be extracted")
        }

        let fallbackTitle = source.fileName.map {
            (($0 as NSString).deletingPathExtension as NSString).lastPathComponent
        } ?? "Untitled"
        let title = comicInfo.title.nonEmpty
            ?? [comicInfo.series.nonEmpty, comicInfo.number.nonEmpty]
                .compactMap { $0 }.joined(separator: " #").nonEmpty
            ?? fallbackTitle
        let authors = comicInfo.writer
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { String($0).normalizedWhitespace() }
            .filter { !$0.isEmpty }
        let publicationDate = Self.publicationDate(
            year: comicInfo.year,
            month: comicInfo.month,
            day: comicInfo.day
        )

        var extensions: [String: String] = [:]
        extensions["bookkit:comicinfo:series"] = comicInfo.series.nonEmpty
        extensions["bookkit:comicinfo:number"] = comicInfo.number.nonEmpty
        extensions["bookkit:comicinfo:summary"] = comicInfo.summary.nonEmpty

        return Book(
            id: DeterministicIdentifier.make(namespace: "cbz", data: data),
            format: .cbz,
            version: comicInfo.version,
            metadata: Metadata(
                title: title,
                authors: authors,
                language: comicInfo.language.nonEmpty,
                publisher: comicInfo.publisher.nonEmpty,
                publicationDate: publicationDate
            ),
            readingOrder: chapters,
            assets: assets,
            tableOfContents: tableOfContents,
            landmarks: tableOfContents.filter { $0.roles.contains("cover") },
            pageList: pageList,
            rawExtensions: extensions,
            diagnostics: diagnostics,
            presentation: BookPresentation(
                layout: .fixed,
                readingProgression: progression,
                spread: .auto,
                coverPageIndex: coverIndex
            )
        )
    }

    private static func isImagePath(_ path: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    private static func isIgnoredPath(_ path: String) -> Bool {
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return components.contains("__MACOSX") || components.contains { $0.hasPrefix(".") }
    }

    private static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        return result == .orderedAscending || (result == .orderedSame && lhs < rhs)
    }

    private static func mediaType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    private static func pageSide(
        index: Int,
        coverIndex: Int,
        progression: ReadingProgression,
        isSpread: Bool
    ) -> PageSide {
        if index == coverIndex || isSpread { return .center }
        let offset = index > coverIndex ? index - coverIndex : index
        if progression == .rightToLeft {
            return offset.isMultiple(of: 2) ? .left : .right
        }
        return offset.isMultiple(of: 2) ? .right : .left
    }

    private static func publicationDate(year: Int?, month: Int?, day: Int?) -> String? {
        guard let year, year > 0 else { return nil }
        var result = String(format: "%04d", year)
        if let month, (1...12).contains(month) {
            result += String(format: "-%02d", month)
            if let day, (1...31).contains(day) {
                result += String(format: "-%02d", day)
            }
        }
        return result
    }
}

private struct ComicInfo {
    struct Page {
        var imageIndex: Int
        var types: [String]
        var isDoublePage: Bool
        var bookmark: String
        var imageWidth: Int?
        var imageHeight: Int?
    }

    var version = "ComicInfo 2.x"
    var title = ""
    var series = ""
    var number = ""
    var summary = ""
    var writer = ""
    var publisher = ""
    var language = ""
    var manga = ""
    var year: Int?
    var month: Int?
    var day: Int?
    var pages: [Page] = []

    static func parse(_ data: Data) throws -> ComicInfo {
        let delegate = ComicInfoXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw BookError.malformedDocument(
                parser.parserError?.localizedDescription ?? "Unable to parse ComicInfo.xml"
            )
        }
        return delegate.result
    }
}

private final class ComicInfoXMLDelegate: NSObject, XMLParserDelegate {
    var result = ComicInfo()
    private var currentElement = ""
    private var currentText = ""

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = elementName.split(separator: ":").last.map(String.init) ?? elementName
        currentText = ""
        guard currentElement == "Page", let index = Int(attributes["Image"] ?? "") else { return }
        result.pages.append(
            ComicInfo.Page(
                imageIndex: index,
                types: (attributes["Type"] ?? "Story").split(whereSeparator: \.isWhitespace).map(String.init),
                isDoublePage: (attributes["DoublePage"] ?? "false").lowercased() == "true",
                bookmark: attributes["Bookmark"] ?? "",
                imageWidth: Int(attributes["ImageWidth"] ?? "").flatMap { $0 > 0 ? $0 : nil },
                imageHeight: Int(attributes["ImageHeight"] ?? "").flatMap { $0 > 0 ? $0 : nil }
            )
        )
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
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let value = currentText.normalizedWhitespace()
        switch local {
        case "Title": result.title = value
        case "Series": result.series = value
        case "Number": result.number = value
        case "Summary": result.summary = value
        case "Writer": result.writer = value
        case "Publisher": result.publisher = value
        case "LanguageISO": result.language = value
        case "Manga": result.manga = value
        case "Year": result.year = Int(value)
        case "Month": result.month = Int(value)
        case "Day": result.day = Int(value)
        default: break
        }
        currentText = ""
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
