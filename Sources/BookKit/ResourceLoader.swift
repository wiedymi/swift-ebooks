import Foundation

public actor ResourceLoader {
    private let book: Book
    private let options: OpenOptions
    private let allowedRoot: URL?
    private let maxAssetBytes: Int

    private var cacheByAssetID: [String: Data] = [:]

    public init(
        book: Book,
        options: OpenOptions = OpenOptions(),
        allowedRoot: URL? = nil,
        maxAssetBytes: Int = 32 * 1024 * 1024
    ) {
        self.book = book
        self.options = options
        self.allowedRoot = allowedRoot
        self.maxAssetBytes = min(max(maxAssetBytes, 1), options.maxResourceBytes)
    }

    public func data(forAssetID id: String) async throws -> Data? {
        if let cached = cacheByAssetID[id] {
            return cached
        }

        guard let asset = book.assets.first(where: { $0.id == id }) else {
            return nil
        }

        if let inMemory = asset.data {
            let validated = try validatedAssetData(inMemory, mediaType: asset.mediaType)
            cacheByAssetID[id] = validated
            return validated
        }

        return nil
    }

    public func data(for url: URL) async throws -> Data? {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "bookkit":
                let id = url.path
                    .split(separator: "/")
                    .map(String.init)
                    .last
                if let id {
                    return try await data(forAssetID: id)
                }
                return nil
            case "http", "https":
                if !options.allowsNetwork {
                    throw BookError.io("Remote asset fetch blocked by OpenOptions")
                }
                let (payload, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode)
                {
                    throw BookError.io("Remote asset returned HTTP \(response.statusCode)")
                }
                return try validatedAssetData(payload, mediaType: nil)
            case "file":
                let fileURL = URL(fileURLWithPath: url.path)
                guard isAllowed(fileURL) else {
                    throw BookError.io("file:// asset outside allowed sandbox root")
                }
                return try options.fileAccess.withReadAccess(to: fileURL) { scoped in
                    try validatedAssetData(Data(contentsOf: scoped), mediaType: nil)
                }
            default:
                return nil
            }
        }

        return nil
    }

    private func validatedAssetData(_ data: Data, mediaType: String?) throws -> Data {
        guard data.count <= maxAssetBytes else {
            throw BookError.io("Asset exceeds configured size limit")
        }

        guard mediaTypeMatchesPayload(data: data, mediaType: mediaType) else {
            throw BookError.io("Asset media type does not match payload header")
        }

        return data
    }

    private func mediaTypeMatchesPayload(data: Data, mediaType: String?) -> Bool {
        guard let mediaType = mediaType?.lowercased() else {
            return true
        }

        switch mediaType {
        case "image/png":
            return data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        case "image/jpeg", "image/jpg":
            return data.starts(with: Data([0xff, 0xd8, 0xff]))
        case "image/gif":
            return data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
        case "application/pdf":
            return data.starts(with: Data("%PDF-".utf8))
        default:
            return true
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        guard let allowedRoot else {
            return true
        }

        let rootPath = allowedRoot.resolvingSymlinksInPath().path
        let filePath = url.resolvingSymlinksInPath().path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }
}
