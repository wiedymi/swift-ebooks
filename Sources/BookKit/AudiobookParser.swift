import Foundation

public struct AudiobookParser: BookParser {
    public let formats: Set<BookFormat> = [.audiobook]

    public init() {}

    public func parse(source: BookSource, options: OpenOptions) async throws -> Book {
        let data = try source.loadData(options: options)
        if data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) {
            return try parsePackage(data, source: source, options: options)
        }
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return try parseManifest(
                data,
                source: source,
                container: nil,
                options: options
            )
        }
        return try await parseStandaloneAudio(data, source: source, options: options)
    }

    private func parsePackage(
        _ data: Data,
        source: BookSource,
        options: OpenOptions
    ) throws -> Book {
        let container = try SafeZIPArchive(data: data, options: options, kind: "audiobook")
        guard let manifestData = try container.data(at: "manifest.json") else {
            throw BookError.invalidContainer("Packaged audiobook is missing root manifest.json")
        }
        return try parseManifest(
            manifestData,
            source: source,
            container: container,
            options: options,
            packageData: data
        )
    }

    private func parseManifest(
        _ data: Data,
        source: BookSource,
        container: SafeZIPArchive?,
        options _: OpenOptions,
        packageData: Data? = nil
    ) throws -> Book {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookError.malformedDocument("Unable to parse audiobook manifest JSON")
        }
        guard let root = object as? [String: Any] else {
            throw BookError.malformedDocument("Audiobook manifest root must be a JSON object")
        }

        let metadata = root["metadata"] as? [String: Any] ?? root
        guard let rawReadingOrder = root["readingOrder"] else {
            throw BookError.malformedDocument("Audiobook manifest has no readingOrder")
        }
        let readingLinks: [[String: Any]]
        if let array = rawReadingOrder as? [[String: Any]] {
            readingLinks = array
        } else if let link = rawReadingOrder as? [String: Any] {
            readingLinks = [link]
        } else {
            throw BookError.malformedDocument("Audiobook readingOrder is invalid")
        }

        try validateDRMFree(links: readingLinks, root: root)
        let sourceBaseURL: URL? = {
            guard container == nil, case let .url(url) = source else { return nil }
            return url.deletingLastPathComponent()
        }()
        var diagnostics: [BookDiagnostic] = []
        var assets: [Asset] = []
        var chapters: [Chapter] = []

        for (index, link) in readingLinks.enumerated() {
            guard let rawHref = string(link["href"]) ?? string(link["url"]), !rawHref.isEmpty else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "audiobook.missing-href",
                        message: "Ignored reading-order item without an href"
                    )
                )
                continue
            }
            let mediaType = string(link["type"])
                ?? string(link["encodingFormat"])
                ?? inferredMediaType(from: rawHref)
            guard mediaType.lowercased().hasPrefix("audio/") else {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "audiobook.non-audio-reading-order-item",
                        message: "Ignored non-audio reading-order item",
                        location: rawHref
                    )
                )
                continue
            }

            let href = resolvedHref(rawHref, baseURL: sourceBaseURL, packaged: container != nil)
            let resourcePath = pathWithoutMediaFragment(rawHref)
            let payload: Data?
            if let container {
                guard let embedded = try container.data(at: resourcePath) else {
                    throw BookError.missingAsset("Packaged audiobook is missing \(resourcePath)")
                }
                payload = embedded
            } else {
                payload = nil
            }
            let resourceID = "audio-track-\(index + 1)"
            let title = string(link["title"])
                ?? string(link["name"])
                ?? "Track \(index + 1)"
            let duration = durationSeconds(link["duration"])
            if duration == nil {
                diagnostics.append(
                    BookDiagnostic(
                        severity: .warning,
                        code: "audiobook.missing-duration",
                        message: "Audio resource has no usable duration",
                        location: href
                    )
                )
            }
            let fragment = mediaFragment(in: rawHref)

            assets.append(
                Asset(id: resourceID, href: href, mediaType: mediaType, data: payload)
            )
            chapters.append(
                Chapter(
                    id: "audio-chapter-\(index + 1)",
                    href: href,
                    title: title,
                    content: title,
                    resourceID: resourceID,
                    mediaType: mediaType,
                    audio: AudioPresentation(
                        duration: duration,
                        clipBegin: fragment?.start ?? 0,
                        clipEnd: fragment?.end
                    )
                )
            )
        }

        guard !chapters.isEmpty else {
            throw BookError.malformedDocument("Audiobook readingOrder contains no audio resources")
        }

        let resourceLinks = root["resources"] as? [[String: Any]] ?? []
        try validateDRMFree(links: resourceLinks, root: [:])
        for (index, link) in resourceLinks.enumerated() {
            guard let rawHref = string(link["href"]) ?? string(link["url"]) else { continue }
            let href = resolvedHref(rawHref, baseURL: sourceBaseURL, packaged: container != nil)
            let mediaType = string(link["type"])
                ?? string(link["encodingFormat"])
                ?? inferredMediaType(from: rawHref)
            let payload = try container?.data(at: pathWithoutMediaFragment(rawHref))
            assets.append(
                Asset(
                    id: "audiobook-resource-\(index + 1)",
                    href: href,
                    mediaType: mediaType,
                    data: payload
                )
            )
        }

        let title = string(metadata["title"])
            ?? string(metadata["name"])
            ?? fallbackTitle(source.fileName)
        let authors = people(metadata["author"])
        let narrators = people(metadata["narrator"] ?? metadata["readBy"])
        let language = string(metadata["language"] ?? metadata["inLanguage"])
        let publisher = people(metadata["publisher"]).first ?? string(metadata["publisher"])
        let publicationDate = string(metadata["published"] ?? metadata["datePublished"])
        let identifier = string(metadata["identifier"] ?? metadata["id"])
        let totalDuration = durationSeconds(metadata["duration"])
            ?? chapters.compactMap { $0.audio?.duration }.reduce(0, +)
        let tocLinks = root["toc"] as? [[String: Any]] ?? []
        let tableOfContents = tocLinks.isEmpty
            ? chapters.map { TOCNode(title: $0.title ?? $0.id, href: $0.href) }
            : navigationNodes(tocLinks, baseURL: sourceBaseURL, packaged: container != nil)

        var extensions: [String: String] = [
            "bookkit:audiobook:duration": String(totalDuration),
        ]
        if !narrators.isEmpty {
            extensions["bookkit:audiobook:narrators"] = narrators.joined(separator: ", ")
        }
        if container != nil {
            extensions["bookkit:container"] = "audiobook.zip"
        }

        return Book(
            id: identifier ?? DeterministicIdentifier.make(
                namespace: "audiobook",
                data: packageData ?? data
            ),
            format: .audiobook,
            version: conformsTo(root).contains("w3.org") ? "W3C" : "Readium",
            metadata: Metadata(
                title: title,
                authors: authors,
                language: language,
                identifiers: identifier.map { ["primary": $0] } ?? [:],
                publisher: publisher,
                publicationDate: publicationDate
            ),
            readingOrder: chapters,
            assets: assets,
            tableOfContents: tableOfContents,
            landmarks: coverLandmarks(resourceLinks, baseURL: sourceBaseURL, packaged: container != nil),
            pageList: [],
            rawExtensions: extensions,
            diagnostics: diagnostics,
            presentation: BookPresentation(layout: .audiobook, spread: .none)
        )
    }

    private func parseStandaloneAudio(
        _ data: Data,
        source: BookSource,
        options: OpenOptions
    ) async throws -> Book {
        guard let fileName = source.fileName,
              let format = BookFormat(fileExtension: (fileName as NSString).pathExtension),
              format == .audiobook
        else {
            throw BookError.invalidContainer("Unrecognized standalone audio resource")
        }
        let mediaType = inferredMediaType(from: fileName)
        let tags = ID3Metadata.parse(data)
        let inspection = try await AudioAssetInspector.inspect(
            data: data,
            fileName: fileName,
            tempDirectory: options.tempDirectory
        )
        let title = inspection.title ?? tags.title ?? fallbackTitle(fileName)
        let href: String
        if case let .url(url) = source {
            href = url.absoluteString
        } else {
            href = fileName
        }
        let asset = Asset(
            id: "audio-track-1",
            href: href,
            mediaType: mediaType,
            data: data
        )
        let chapters: [Chapter]
        if inspection.chapters.isEmpty {
            chapters = [
                Chapter(
                    id: "audio-chapter-1",
                    href: href,
                    title: title,
                    content: title,
                    resourceID: asset.id,
                    mediaType: mediaType,
                    audio: AudioPresentation(duration: inspection.duration)
                ),
            ]
        } else {
            chapters = inspection.chapters.enumerated().map { index, chapter in
                Chapter(
                    id: "audio-chapter-\(index + 1)",
                    href: "\(href)#t=\(chapter.start),\(chapter.end)",
                    title: chapter.title ?? "Chapter \(index + 1)",
                    content: chapter.title ?? "Chapter \(index + 1)",
                    resourceID: asset.id,
                    mediaType: mediaType,
                    audio: AudioPresentation(
                        duration: chapter.end - chapter.start,
                        clipBegin: chapter.start,
                        clipEnd: chapter.end
                    )
                )
            }
        }
        var assets = [asset]
        if let artwork = inspection.artwork {
            assets.append(
                Asset(
                    id: "audio-cover",
                    href: "embedded-cover",
                    mediaType: "image/jpeg",
                    data: artwork
                )
            )
        }
        return Book(
            id: DeterministicIdentifier.make(namespace: "audiobook", data: data),
            format: .audiobook,
            version: "standalone",
            metadata: Metadata(
                title: title,
                authors: (inspection.artist ?? tags.artist).map { [$0] } ?? []
            ),
            readingOrder: chapters,
            assets: assets,
            tableOfContents: chapters.map { TOCNode(title: $0.title ?? $0.id, href: $0.href) },
            landmarks: inspection.artwork == nil
                ? []
                : [TOCNode(title: "Cover", href: "embedded-cover", roles: ["cover"])],
            pageList: [],
            rawExtensions: ["bookkit:container": "standalone-audio"],
            diagnostics: [],
            presentation: BookPresentation(layout: .audiobook, spread: .none)
        )
    }

    private func validateDRMFree(links: [[String: Any]], root: [String: Any]) throws {
        if let encryption = root["encryption"] ?? root["encrypted"], isProtectionPresent(encryption) {
            throw BookError.protectedContent(
                ContentProtection(kind: .audioDRM, scheme: scheme(from: encryption))
            )
        }
        for link in links {
            let properties = link["properties"] as? [String: Any]
            guard let encrypted = properties?["encrypted"] ?? link["encrypted"],
                  isProtectionPresent(encrypted)
            else {
                continue
            }
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .audioDRM,
                    scheme: scheme(from: encrypted),
                    resource: string(link["href"] ?? link["url"])
                )
            )
        }
    }

    private func isProtectionPresent(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let flag = value as? Bool { return flag }
        if let string = value as? String { return !string.isEmpty && string.lowercased() != "none" }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        return true
    }

    private func scheme(from value: Any) -> String {
        if let value = value as? String { return value }
        if let object = value as? [String: Any] {
            return string(object["scheme"] ?? object["algorithm"] ?? object["profile"])
                ?? "protected audio"
        }
        return "protected audio"
    }

    private func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func people(_ value: Any?) -> [String] {
        if let string = string(value) { return [string] }
        if let object = value as? [String: Any], let name = string(object["name"]) { return [name] }
        if let array = value as? [Any] { return array.flatMap(people) }
        return []
    }

    private func durationSeconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return max(number.doubleValue, 0) }
        guard let value = string(value) else { return nil }
        if let number = Double(value) { return max(number, 0) }
        guard let regex = try? NSRegularExpression(
            pattern: "^P(?:(\\d+(?:\\.\\d+)?)D)?(?:T(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?)?$",
            options: .caseInsensitive
        ),
            let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
            )
        else {
            return nil
        }
        func capture(_ index: Int) -> Double {
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            return Double(value[range]) ?? 0
        }
        return capture(1) * 86_400 + capture(2) * 3_600 + capture(3) * 60 + capture(4)
    }

    private func mediaFragment(in href: String) -> (start: Double, end: Double?)? {
        guard let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first,
              let time = String(fragment).firstMatch(for: "(?:^|&)t=(?:npt:)?([0-9.]+(?:,[0-9.]*)?)")
        else {
            return nil
        }
        let values = time.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = values.first.flatMap({ Double($0) }) else { return nil }
        let end = values.count > 1 ? Double(values[1]) : nil
        return (max(start, 0), end.map { max($0, start) })
    }

    private func pathWithoutMediaFragment(_ href: String) -> String {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        return (path.removingPercentEncoding ?? path).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    private func resolvedHref(_ href: String, baseURL: URL?, packaged: Bool) -> String {
        if packaged { return href }
        guard let baseURL, let url = URL(string: href, relativeTo: baseURL) else { return href }
        return url.absoluteURL.absoluteString
    }

    private func inferredMediaType(from href: String) -> String {
        let path = pathWithoutMediaFragment(href)
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav", "wave": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "html", "htm": return "text/html"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private func navigationNodes(
        _ links: [[String: Any]],
        baseURL: URL?,
        packaged: Bool
    ) -> [TOCNode] {
        links.enumerated().compactMap { index, link in
            guard let href = string(link["href"] ?? link["url"]) else { return nil }
            let title = string(link["title"] ?? link["name"]) ?? "Section \(index + 1)"
            let children = navigationNodes(
                link["children"] as? [[String: Any]] ?? [],
                baseURL: baseURL,
                packaged: packaged
            )
            return TOCNode(
                id: "audiobook-toc-\(index)-\(href)",
                title: title,
                href: resolvedHref(href, baseURL: baseURL, packaged: packaged),
                children: children
            )
        }
    }

    private func coverLandmarks(
        _ links: [[String: Any]],
        baseURL: URL?,
        packaged: Bool
    ) -> [TOCNode] {
        links.compactMap { link in
            let rels: [String]
            if let rel = string(link["rel"]) { rels = [rel] }
            else { rels = (link["rel"] as? [String]) ?? [] }
            guard rels.contains("cover"), let href = string(link["href"] ?? link["url"]) else {
                return nil
            }
            return TOCNode(
                title: "Cover",
                href: resolvedHref(href, baseURL: baseURL, packaged: packaged),
                roles: ["cover"]
            )
        }
    }

    private func conformsTo(_ root: [String: Any]) -> String {
        let metadata = root["metadata"] as? [String: Any]
        if let value = string(metadata?["conformsTo"] ?? root["conformsTo"]) { return value }
        if let values = metadata?["conformsTo"] as? [String] { return values.joined(separator: " ") }
        if let values = root["conformsTo"] as? [String] { return values.joined(separator: " ") }
        return ""
    }

    private func fallbackTitle(_ fileName: String?) -> String {
        guard let fileName else { return "Untitled" }
        return ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent
    }
}

private struct ID3Metadata {
    var title: String?
    var artist: String?

    static func parse(_ data: Data) -> ID3Metadata {
        guard data.count >= 10, data.starts(with: Data("ID3".utf8)) else { return ID3Metadata() }
        let tagSize = syncSafe(data[6], data[7], data[8], data[9])
        var offset = 10
        let upper = min(data.count, 10 + tagSize)
        var result = ID3Metadata()
        while offset + 10 <= upper {
            guard let frameID = String(data: data[offset..<(offset + 4)], encoding: .ascii),
                  frameID.allSatisfy({ $0.isLetter || $0.isNumber })
            else {
                break
            }
            let size = Int(data[offset + 4]) << 24 |
                Int(data[offset + 5]) << 16 |
                Int(data[offset + 6]) << 8 |
                Int(data[offset + 7])
            guard size > 0, offset + 10 + size <= upper else { break }
            let payload = Data(data[(offset + 10)..<(offset + 10 + size)])
            let value = decodeTextFrame(payload)
            if frameID == "TIT2" { result.title = value }
            if frameID == "TPE1" { result.artist = value }
            offset += 10 + size
        }
        return result
    }

    private static func syncSafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7f) << 21 | Int(b & 0x7f) << 14 | Int(c & 0x7f) << 7 | Int(d & 0x7f)
    }

    private static func decodeTextFrame(_ data: Data) -> String? {
        guard let encoding = data.first else { return nil }
        let payload = data.dropFirst()
        let value: String?
        switch encoding {
        case 0: value = String(data: payload, encoding: .isoLatin1)
        case 1: value = String(data: payload, encoding: .utf16)
        case 2: value = String(data: payload, encoding: .utf16BigEndian)
        default: value = String(data: payload, encoding: .utf8)
        }
        return value?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)).nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
