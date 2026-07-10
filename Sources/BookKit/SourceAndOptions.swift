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

    public init(
        allowsNetwork: Bool = false,
        tempDirectory: URL? = nil,
        fileAccess: any FileAccessPolicy = SandboxFileAccessPolicy()
    ) {
        self.allowsNetwork = allowsNetwork
        self.tempDirectory = tempDirectory
        self.fileAccess = fileAccess
    }
}

public enum BookSource: Sendable {
    case url(URL)
    case data(Data, fileName: String?)
    case stream(fileName: String?, provider: @Sendable () throws -> Data)

    var fileName: String? {
        switch self {
        case let .url(url):
            return url.lastPathComponent
        case let .data(_, fileName):
            return fileName
        case let .stream(fileName, _):
            return fileName
        }
    }

    func loadData(options: OpenOptions) throws -> Data {
        switch self {
        case let .data(data, _):
            return data
        case let .stream(_, provider):
            return try provider()
        case let .url(url):
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                if !options.allowsNetwork {
                    throw BookError.io("Network access is disabled by OpenOptions")
                }
                let data = try Data(contentsOf: url)
                return data
            }

            return try options.fileAccess.withReadAccess(to: url) { scopedURL in
                try Data(contentsOf: scopedURL)
            }
        }
    }
}
