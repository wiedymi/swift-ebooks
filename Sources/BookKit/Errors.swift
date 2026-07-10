import Foundation

public enum BookError: Error, Sendable, Equatable {
    case unsupportedFormat
    case invalidContainer(String)
    case malformedDocument(String)
    case missingAsset(String)
    case renderingFailed(String)
    case io(String)

    static func from(_ error: Error) -> BookError {
        if let error = error as? BookError {
            return error
        }
        return .io(String(describing: error))
    }
}
