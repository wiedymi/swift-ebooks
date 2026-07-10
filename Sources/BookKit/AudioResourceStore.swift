import Foundation

public actor AudioResourceStore {
    private let book: Book
    private let allowsNetwork: Bool
    private let directory: URL
    private var materializedURLs: [String: URL] = [:]

    public init(book: Book, options: OpenOptions = OpenOptions()) {
        self.book = book
        allowsNetwork = options.allowsNetwork
        let root = options.tempDirectory ?? FileManager.default.temporaryDirectory
        let namespace = DeterministicIdentifier.make(
            namespace: "audio-cache",
            data: Data(book.id.utf8)
        )
        directory = root
            .appendingPathComponent("BookKitAudio", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    public func url(forTrackAt index: Int) throws -> URL {
        guard book.readingOrder.indices.contains(index) else {
            throw BookError.navigationFailed("Audiobook track index is out of bounds")
        }
        let chapter = book.readingOrder[index]
        if let cached = materializedURLs[chapter.id] {
            return cached
        }

        let asset = chapter.resourceID.flatMap { id in
            book.assets.first(where: { $0.id == id })
        } ?? book.assets.first(where: { $0.href == chapter.href })
        if let payload = asset?.data {
            try AudioProtectionProbe.validate(
                payload,
                resource: asset?.href ?? chapter.href
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let pathExtension = Self.pathExtension(
                href: asset?.href ?? chapter.href,
                mediaType: asset?.mediaType ?? chapter.mediaType
            )
            let url = directory
                .appendingPathComponent("track-\(index + 1)")
                .appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: url.path) {
                try payload.write(to: url, options: .atomic)
            }
            materializedURLs[chapter.id] = url
            return url
        }

        guard let url = URL(string: chapter.href), let scheme = url.scheme?.lowercased() else {
            throw BookError.missingAsset("No payload or absolute URL for audio track \(index + 1)")
        }
        if scheme == "http" || scheme == "https" {
            guard allowsNetwork else {
                throw BookError.io("Network audio is disabled by OpenOptions")
            }
            #if os(visionOS)
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .audioDRM,
                    scheme: "remote audio protection cannot be verified on visionOS",
                    resource: url.absoluteString
                )
            )
            #else
            return url
            #endif
        }
        guard scheme == "file" else {
            throw BookError.missingAsset("Unsupported audio URL scheme: \(scheme)")
        }
        try AudioProtectionProbe.validateFile(at: url)
        return url
    }

    public func removeAll() throws {
        materializedURLs.removeAll()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func pathExtension(href: String, mediaType: String?) -> String {
        let rawPath = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let pathExtension = (rawPath as NSString).pathExtension
        if !pathExtension.isEmpty { return pathExtension }
        switch mediaType?.lowercased() {
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav": return "wav"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/flac": return "flac"
        default: return "audio"
        }
    }
}
