import Foundation

public enum ReadingMode: String, Sendable, Equatable, Hashable, Codable {
    case paginated
    case scroll
}

public struct ReaderPreferences: Sendable, Equatable, Hashable, Codable {
    public var readingMode: ReadingMode
    public var theme: Theme
    public var typography: Typography

    public init(
        readingMode: ReadingMode = .scroll,
        theme: Theme = .light,
        typography: Typography = .default
    ) {
        self.readingMode = readingMode
        self.theme = theme
        self.typography = typography
    }

    public static let `default` = ReaderPreferences()
}

public struct ReaderAccessibilitySettings: Sendable, Equatable, Hashable, Codable {
    public var isVoiceOverEnabled: Bool
    public var forceScrollWhenVoiceOverEnabled: Bool

    public init(
        isVoiceOverEnabled: Bool = false,
        forceScrollWhenVoiceOverEnabled: Bool = true
    ) {
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.forceScrollWhenVoiceOverEnabled = forceScrollWhenVoiceOverEnabled
    }

    public static let `default` = ReaderAccessibilitySettings()
}

public struct Locator: Sendable, Equatable, Hashable, Codable {
    public var sectionIndex: Int
    public var sectionHref: String?
    public var sectionProgression: Double
    public var totalProgression: Double
    public var anchor: String?
    public var cfi: String?
    public var textContext: TextContext?

    public init(
        sectionIndex: Int,
        sectionHref: String?,
        sectionProgression: Double,
        totalProgression: Double,
        anchor: String?,
        cfi: String?,
        textContext: TextContext?
    ) {
        self.sectionIndex = max(sectionIndex, 0)
        self.sectionHref = sectionHref
        self.sectionProgression = min(max(sectionProgression, 0), 1)
        self.totalProgression = min(max(totalProgression, 0), 1)
        self.anchor = anchor
        self.cfi = cfi
        self.textContext = textContext
    }

    public var position: Position {
        Position(
            spineIndex: sectionIndex,
            progression: sectionProgression,
            cfi: cfi,
            fragment: anchor,
            textContext: textContext
        )
    }
}

public extension Locator {
    static let start = Locator(
        sectionIndex: 0,
        sectionHref: nil,
        sectionProgression: 0,
        totalProgression: 0,
        anchor: nil,
        cfi: nil,
        textContext: nil
    )
}

public enum DecorationGroup: String, Sendable, Equatable, Hashable, Codable {
    case highlight
    case search
    case tts
}

public struct DecorationStyle: Sendable, Equatable, Hashable, Codable {
    public var backgroundColor: String?
    public var textColor: String?
    public var underlineColor: String?

    public init(
        backgroundColor: String? = nil,
        textColor: String? = nil,
        underlineColor: String? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.underlineColor = underlineColor
    }

    public static func `default`(for group: DecorationGroup) -> DecorationStyle {
        switch group {
        case .highlight:
            return DecorationStyle(backgroundColor: "#fff5a8", textColor: nil, underlineColor: "#f7d547")
        case .search:
            return DecorationStyle(backgroundColor: "#ffe58f", textColor: "#1a1a1a", underlineColor: "#ffb300")
        case .tts:
            return DecorationStyle(backgroundColor: "#d0ebff", textColor: "#0b3866", underlineColor: "#4dabf7")
        }
    }
}

public struct Decoration: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    public var group: DecorationGroup
    public var locator: Locator
    public var style: DecorationStyle

    public init(
        id: String,
        group: DecorationGroup,
        locator: Locator,
        style: DecorationStyle = .init()
    ) {
        self.id = id
        self.group = group
        self.locator = locator
        self.style = style
    }
}

public struct DecorationTapEvent: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var group: DecorationGroup
    public var locator: Locator?

    public init(id: String, group: DecorationGroup, locator: Locator?) {
        self.id = id
        self.group = group
        self.locator = locator
    }
}

public enum NavigatorEvent: Sendable, Equatable {
    case locatorChanged(Locator)
    case historyChanged(canGoBack: Bool, canGoForward: Bool)
    case readingModeChanged(ReadingMode)
    case preferencesChanged(ReaderPreferences)
    case accessibilityChanged(ReaderAccessibilitySettings)
    case linkActivated(url: URL, kind: LinkKind, action: LinkAction)
    case decorationTapped(DecorationTapEvent)
}

@MainActor
public protocol Navigator: AnyObject {
    var events: AsyncStream<NavigatorEvent> { get }

    func currentLocator() async -> Locator
    func go(to locator: Locator) async throws
    func goBack() async throws -> Locator?
    func goForward() async throws -> Locator?
    func canGoBack() -> Bool
    func canGoForward() -> Bool

    func preferences() async -> ReaderPreferences
    func setPreferences(_ preferences: ReaderPreferences) async throws
    func readingMode() async -> ReadingMode
    func setReadingMode(_ mode: ReadingMode) async throws

    func accessibility() -> ReaderAccessibilitySettings
    func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws
}

public extension Book {
    func locator(for position: Position) -> Locator {
        let sectionCount = max(readingOrder.count, 1)
        let index = min(max(position.spineIndex, 0), sectionCount - 1)
        let sectionProgression = min(max(position.progression, 0), 1)
        let total = min(max((Double(index) + sectionProgression) / Double(sectionCount), 0), 1)
        let href = readingOrder.indices.contains(index) ? readingOrder[index].href : nil

        return Locator(
            sectionIndex: index,
            sectionHref: href,
            sectionProgression: sectionProgression,
            totalProgression: total,
            anchor: position.fragment,
            cfi: position.cfi,
            textContext: position.textContext
        )
    }
}
