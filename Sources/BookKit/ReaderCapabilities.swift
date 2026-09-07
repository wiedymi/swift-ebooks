import Foundation

/// Features supported by the active presentation. Text may still be absent in a particular book.
public struct ReaderCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let search = ReaderCapabilities(rawValue: 1 << 0)
    public static let textSelection = ReaderCapabilities(rawValue: 1 << 1)
    public static let textDecorations = ReaderCapabilities(rawValue: 1 << 2)
    public static let speech = ReaderCapabilities(rawValue: 1 << 3)
    public static let pageOverlays = ReaderCapabilities(rawValue: 1 << 4)
}

extension BookReader {
    public var capabilities: ReaderCapabilities {
        switch presentationEngine {
        case .reflow, .xhtmlFixed:
            return [.search, .textSelection, .textDecorations, .speech]
        case .pdf:
            #if canImport(PDFKit) && !os(tvOS)
                return [.search, .textSelection, .textDecorations, .speech]
            #else
                return [.search, .speech]
            #endif
        case .bitmapFixed:
            return [.search, .speech, .pageOverlays]
        case .audio:
            return []
        }
    }
}
