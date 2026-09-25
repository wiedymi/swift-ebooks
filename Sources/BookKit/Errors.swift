import Foundation

public enum ContentProtectionKind: String, Sendable, Equatable, Hashable, Codable {
    case zipEncryption
    case epubEncryption
    case pdfEncryption
    case kindleDRM
    case audioDRM
    case djvuEncryption
    case unknown
}

public struct ContentProtection: Sendable, Equatable, Hashable, Codable {
    public var kind: ContentProtectionKind
    public var scheme: String?
    public var resource: String?

    public init(kind: ContentProtectionKind, scheme: String? = nil, resource: String? = nil) {
        self.kind = kind
        self.scheme = scheme
        self.resource = resource
    }
}

public enum BookError: Error, Sendable, Equatable {
    case speechLanguageUnavailable(String)
    case speechVoiceUnavailable(String)
    case unsupportedFormat
    case protectedContent(ContentProtection)
    case invalidContainer(String)
    case malformedDocument(String)
    case missingAsset(String)
    case renderingFailed(String)
    case navigationFailed(String)
    case io(String)

    static func from(_ error: Error) -> BookError {
        if let error = error as? BookError {
            return error
        }
        return .io(String(describing: error))
    }
}

extension BookError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .speechLanguageUnavailable:
            return "Read Aloud is not available for this language on this device."
        case .speechVoiceUnavailable:
            return "The selected voice is not available on this device."
        case .unsupportedFormat:
            return "This ebook format or encoding is not supported."
        case let .protectedContent(protection):
            let scheme = protection.scheme.map { " Scheme: \($0)." } ?? ""
            let resource = protection.resource.map { " Resource: \($0)." } ?? ""
            return "BookKit opens DRM-free publications only; this file contains protected content.\(scheme)\(resource)"
        case let .invalidContainer(message):
            return "Invalid ebook container: \(message)"
        case let .malformedDocument(message):
            return "Malformed ebook document: \(message)"
        case let .missingAsset(message):
            return "Missing ebook asset: \(message)"
        case let .renderingFailed(message):
            return "Ebook rendering failed: \(message)"
        case let .navigationFailed(message):
            return "Ebook navigation failed: \(message)"
        case let .io(message):
            return "Ebook I/O failed: \(message)"
        }
    }
}
