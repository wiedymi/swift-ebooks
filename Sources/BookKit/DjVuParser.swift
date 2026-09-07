import Foundation

struct DjVuParser: BookParser {
    public let formats: Set<BookFormat> = [.djvu]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try await source.loadData(options: options)
        if data.starts(with: Data("SDJV".utf8)) {
            throw BookError.protectedContent(
                ContentProtection(kind: .djvuEncryption, scheme: "Secure DjVu")
            )
        }
        let document = try DjVuIFFParser.parse(data, options: options)
        var assets: [Asset] = []
        var chapters: [Chapter] = []
        var pageList: [TOCNode] = []
        var diagnostics: [BookDiagnostic] = []
        var directory: DjVuDirectory?

        if document.formType == "DJVM", let directoryChunk = document.root.children.first {
            do {
                directory = try DjVuDirectoryParser.parse(
                    chunk: directoryChunk,
                    documentData: data,
                    options: options
                )
                if directory?.pages.count != document.pages.count {
                    diagnostics.append(
                        BookDiagnostic(
                            severity: .warning,
                            code: "djvu.directory-page-count-mismatch",
                            message: "The DjVu directory page count differs from the bundled page count."
                        )
                    )
                }
            } catch BookError.malformedDocument(let message) {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "djvu.directory-unavailable",
                        message: "\(message); physical page order is used."
                    )
                )
            }
        }

        var tableOfContents: [TOCNode] = []
        if let navigationChunk = document.root.children.first(where: { $0.id == "NAVM" }) {
            do {
                tableOfContents = try DjVuOutlineParser.parse(
                    chunk: navigationChunk,
                    documentData: data,
                    directory: directory,
                    options: options
                )
            } catch BookError.malformedDocument(let message) {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "djvu.outline-unavailable",
                        message: message
                    )
                )
            }
        }

        let directoryPages = directory?.pages ?? []
        let componentResolver = DjVuComponentResolver(
            root: document.root,
            directory: directory,
            documentData: data,
            options: options
        )

        for (index, page) in document.pages.enumerated() {
            let pageChunks = try componentResolver.expandedChunks(for: page)
            let sharedSymbols = try DjVuPageDecoder.decodeDictionaries(
                chunks: pageChunks,
                documentData: data,
                options: options
            )
            let image = try DjVuPageDecoder.decode(
                page: page,
                chunks: pageChunks,
                sharedSymbols: sharedSymbols,
                documentData: data,
                options: options
            )
            let id = "djvu-page-\(index + 1)"
            let href = "page-\(index + 1)"
            let title = directoryPages.indices.contains(index)
                ? directoryPages[index].title ?? "Page \(index + 1)"
                : "Page \(index + 1)"
            let text = try pageText(pageChunks, documentData: data, options: options)
            let annotations = try pageAnnotations(pageChunks, documentData: data, options: options)
            let links = DjVuAnnotations.links(
                from: annotations,
                pageHeight: Double(image.height)
            ) {
                DjVuNavigationTarget.resolve(
                    $0,
                    directory: directory,
                    currentPageIndex: index,
                    pageCount: document.pages.count
                )
            }

            assets.append(Asset(id: id, href: href, mediaType: image.mediaType, data: image.data))
            chapters.append(
                Chapter(
                    id: id,
                    href: href,
                    title: title,
                    content: text,
                    resourceID: id,
                    mediaType: image.mediaType,
                    page: PagePresentation(
                        side: .center,
                        isCover: index == 0,
                        pixelWidth: image.width,
                        pixelHeight: image.height,
                        links: links
                    )
                )
            )
            pageList.append(
                TOCNode(
                    id: "djvu-page-list-\(index + 1)",
                    title: title,
                    href: href,
                    roles: index == 0 ? ["cover"] : []
                )
            )
        }

        let candidateTitle = source.fileName.map {
            (($0 as NSString).deletingPathExtension as NSString).lastPathComponent
        }
        let fileTitle = candidateTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let highestMinorVersion = document.pages.map(\.info.minorVersion).max() ?? 0

        return Book(
            id: DeterministicIdentifier.make(namespace: "djvu", data: data),
            format: .djvu,
            version: "0.\(highestMinorVersion)",
            metadata: Metadata(title: fileTitle, authors: []),
            readingOrder: chapters,
            assets: assets,
            tableOfContents: tableOfContents,
            landmarks: pageList.prefix(1).map { $0 },
            pageList: pageList,
            rawExtensions: [
                "bookkit:djvu:container": document.formType,
                "bookkit:djvu:decoder": "clean-room",
                "bookkit:djvu:directory-version": directory.map { String($0.version) } ?? "",
            ],
            diagnostics: diagnostics,
            presentation: BookPresentation(
                layout: .fixed,
                readingProgression: .leftToRight,
                spread: .auto,
                coverPageIndex: 0
            )
        )
    }

    private func pageText(
        _ pageChunks: [DjVuIFFChunk],
        documentData: Data,
        options: OpenOptions
    ) throws -> String {
        let chunks = pageChunks.filter { $0.id == "TXTa" || $0.id == "TXTz" }
        var output: [String] = []
        for chunk in chunks {
            let encoded = chunk.payload(in: documentData)
            let payload = chunk.id == "TXTz"
                ? try DjVuBZZDecoder.decode(encoded, maxOutputBytes: options.maxResourceBytes)
                : encoded
            guard payload.count >= 4 else {
                throw BookError.malformedDocument("DjVu text chunk is truncated")
            }
            let length = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
            guard length <= payload.count - 4 else {
                throw BookError.malformedDocument("DjVu text length exceeds the chunk")
            }
            let textData = payload.subdata(in: 3..<(3 + length))
            guard let text = String(data: textData, encoding: .utf8) else {
                throw BookError.malformedDocument("DjVu text is not valid UTF-8")
            }
            output.append(text)
        }
        return output.joined(separator: "\n")
    }

    private func pageAnnotations(
        _ pageChunks: [DjVuIFFChunk],
        documentData: Data,
        options: OpenOptions
    ) throws -> String {
        let chunks = pageChunks.filter { $0.id == "ANTa" || $0.id == "ANTz" }
        return try chunks.map { chunk in
            let encoded = chunk.payload(in: documentData)
            let payload = chunk.id == "ANTz"
                ? try DjVuBZZDecoder.decode(encoded, maxOutputBytes: options.maxResourceBytes)
                : encoded
            guard let value = String(data: payload, encoding: .utf8) else {
                throw BookError.malformedDocument("DjVu annotation is not valid UTF-8")
            }
            return value
        }.joined(separator: " ")
    }
}

private struct DjVuComponentResolver {
    let formsByIdentifier: [String: DjVuIFFChunk]
    let documentData: Data
    let options: OpenOptions

    init(
        root: DjVuIFFChunk,
        directory: DjVuDirectory?,
        documentData: Data,
        options: OpenOptions
    ) {
        self.documentData = documentData
        self.options = options
        let forms = root.children.filter { $0.id == "FORM" }
        var result: [String: DjVuIFFChunk] = [:]
        if let directory {
            for (index, entry) in directory.entries.enumerated() {
                let form = entry.offset.flatMap { offset in
                    forms.first(where: { $0.headerOffset == offset })
                } ?? (forms.indices.contains(index) ? forms[index] : nil)
                guard let form else { continue }
                result[Self.key(entry.id)] = form
                result[Self.key(entry.name)] = form
            }
        }
        formsByIdentifier = result
    }

    func expandedChunks(for page: DjVuIFFPage) throws -> [DjVuIFFChunk] {
        var visited: Set<Int> = []
        var expanded: [DjVuIFFChunk] = []
        try append(
            page.chunks,
            to: &expanded,
            visitedForms: &visited,
            depth: 0
        )
        return expanded
    }

    private func append(
        _ chunks: [DjVuIFFChunk],
        to output: inout [DjVuIFFChunk],
        visitedForms: inout Set<Int>,
        depth: Int
    ) throws {
        guard depth <= 16 else {
            throw BookError.malformedDocument("DjVu included-component nesting is too deep")
        }
        for chunk in chunks {
            guard chunk.id == "INCL" else {
                output.append(chunk)
                continue
            }
            let identifier = try Self.componentIdentifier(chunk.payload(in: documentData))
            guard let form = formsByIdentifier[Self.key(identifier)] else {
                throw BookError.malformedDocument(
                    "DjVu included component \(identifier) is unavailable in this source"
                )
            }
            guard visitedForms.insert(form.headerOffset).inserted else {
                throw BookError.malformedDocument("DjVu included components contain a cycle")
            }
            guard form.children.count <= options.maxArchiveEntries - output.count else {
                throw BookError.invalidContainer("DjVu expanded component count exceeds the configured limit")
            }
            try append(
                form.children,
                to: &output,
                visitedForms: &visitedForms,
                depth: depth + 1
            )
            visitedForms.remove(form.headerOffset)
        }
    }

    private static func componentIdentifier(_ data: Data) throws -> String {
        guard var value = String(data: data, encoding: .utf8) else {
            throw BookError.malformedDocument("DjVu INCL identifier is not valid UTF-8")
        }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        guard !value.isEmpty else {
            throw BookError.malformedDocument("DjVu INCL identifier is empty")
        }
        return value
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
