import Foundation

public struct Viewport: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }
}

public struct Theme: Sendable, Equatable, Hashable, Codable {
    public var backgroundColor: String
    public var textColor: String
    public var linkColor: String
    public var customCSS: String

    public init(
        backgroundColor: String = "#ffffff",
        textColor: String = "#111111",
        linkColor: String = "#0b57d0",
        customCSS: String = ""
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.linkColor = linkColor
        self.customCSS = customCSS
    }

    public static let light = Theme()
    public static let dark = Theme(backgroundColor: "#111111", textColor: "#f3f3f3", linkColor: "#8ab4f8")
}

public struct Typography: Sendable, Equatable, Hashable, Codable {
    public var fontFamily: String
    public var fontSize: Double
    public var lineHeight: Double
    public var letterSpacing: Double

    public init(
        fontFamily: String = "-apple-system",
        fontSize: Double = 18,
        lineHeight: Double = 1.5,
        letterSpacing: Double = 0
    ) {
        self.fontFamily = fontFamily
        self.fontSize = max(fontSize, 10)
        self.lineHeight = max(lineHeight, 1)
        self.letterSpacing = letterSpacing
    }

    public static let `default` = Typography()
}

enum RenderMode: Sendable, Equatable {
    case reflow
    case fixed
    case pdf
    case audio
}

public struct PageMap: Sendable, Equatable {
    public var pageCount: Int
    public var chapterProgressMap: [Int: [Double]]

    public init(pageCount: Int = 1, chapterProgressMap: [Int: [Double]] = [:]) {
        self.pageCount = max(pageCount, 1)
        self.chapterProgressMap = chapterProgressMap
    }
}

public enum LinkKind: String, Sendable {
    case anchor
    case spine
    case external
    case unsupported
}

public struct SelectionRange: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var context: TextContext?
    /// Selection bounds in the content view, in points.
    public var bounds: CGRect?

    public init(start: Int, end: Int, context: TextContext? = nil, bounds: CGRect? = nil) {
        self.start = max(start, 0)
        self.end = max(end, self.start)
        self.context = context
        self.bounds = bounds
    }
}
