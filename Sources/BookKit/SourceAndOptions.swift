import Foundation

public protocol FileAccessPolicy: Sendable {
    func withReadAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T
}

public struct SandboxFileAccessPolicy: FileAccessPolicy, Sendable {
    public init() {}

    public func withReadAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
}

public struct OpenOptions: Sendable {
    public var allowsNetwork: Bool
    public var tempDirectory: URL?
    public var fileAccess: any FileAccessPolicy
    public var maxSourceBytes: Int
    public var maxResourceBytes: Int
    public var maxArchiveUncompressedBytes: Int
    public var maxArchiveEntries: Int

    public init(
        allowsNetwork: Bool = false,
        tempDirectory: URL? = nil,
        fileAccess: any FileAccessPolicy = SandboxFileAccessPolicy(),
        maxSourceBytes: Int = 512 * 1024 * 1024,
        maxResourceBytes: Int = 64 * 1024 * 1024,
        maxArchiveUncompressedBytes: Int = 1024 * 1024 * 1024,
        maxArchiveEntries: Int = 10_000
    ) {
        self.allowsNetwork = allowsNetwork
        self.tempDirectory = tempDirectory
        self.fileAccess = fileAccess
        self.maxSourceBytes = max(maxSourceBytes, 1)
        self.maxResourceBytes = max(maxResourceBytes, 1)
        self.maxArchiveUncompressedBytes = max(maxArchiveUncompressedBytes, 1)
        self.maxArchiveEntries = max(maxArchiveEntries, 1)
    }
}

/// The bytes or location used to open a publication.
public enum BookSource: Sendable {
    /// A local file or remote URL.
    case url(URL)

    /// In-memory publication data and an optional format-bearing file name.
    case data(Data, fileName: String?)

    /// Lazily supplied publication data and an optional format-bearing file name.
    case dataProvider(fileName: String?, provider: @Sendable () throws -> Data)

    var fileName: String? {
        switch self {
        case let .url(url):
            return url.lastPathComponent
        case let .data(_, fileName):
            return fileName
        case let .dataProvider(fileName, _):
            return fileName
        }
    }

    func loadData(options: OpenOptions) async throws -> Data {
        let data: Data
        switch self {
        case let .data(payload, _):
            data = payload
        case let .dataProvider(_, provider):
            data = try provider()
        case let .url(url):
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                if !options.allowsNetwork {
                    throw BookError.io("Network access is disabled by OpenOptions")
                }
                data = try await BoundedDataReader.remote(url, limit: options.maxSourceBytes)
                break
            }

            data = try options.fileAccess.withReadAccess(to: url) { scopedURL in
                try BoundedDataReader.file(scopedURL, limit: options.maxSourceBytes)
            }
        }
        guard data.count <= options.maxSourceBytes else {
            throw BookError.io("Source exceeds configured size limit")
        }
        return data
    }
}
