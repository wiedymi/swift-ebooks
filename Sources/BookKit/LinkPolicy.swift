import Foundation

public enum LinkAction: Sendable, Equatable {
    case follow
    case openExternally
    case block
}

public struct LinkContext: Sendable, Equatable {
    public var currentChapterHref: String

    public init(currentChapterHref: String) {
        self.currentChapterHref = currentChapterHref
    }
}

public protocol LinkPolicy: Sendable {
    func action(for url: URL, context: LinkContext) async -> LinkAction
}

public struct DefaultLinkPolicy: LinkPolicy, Sendable {
    public init() {}

    public func action(for url: URL, context _: LinkContext) async -> LinkAction {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "javascript":
                return .block
            case "http", "https":
                return .block
            case "bookkit":
                return .follow
            case "file":
                return .block
            default:
                return .block
            }
        }

        return .follow
    }
}
