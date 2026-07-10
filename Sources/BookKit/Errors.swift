import Foundation

public enum BookError: Error, Sendable, Equatable {
    case unsupportedFormat
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
        case .unsupportedFormat:
            return "This ebook format or encoding is not supported."
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
