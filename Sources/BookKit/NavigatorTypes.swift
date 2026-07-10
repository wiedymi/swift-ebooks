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
    public var prefersReducedMotion: Bool
    public var announcesPositionChanges: Bool

    public init(
        isVoiceOverEnabled: Bool = false,
        forceScrollWhenVoiceOverEnabled: Bool = true,
        prefersReducedMotion: Bool = false,
        announcesPositionChanges: Bool = false
    ) {
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.forceScrollWhenVoiceOverEnabled = forceScrollWhenVoiceOverEnabled
        self.prefersReducedMotion = prefersReducedMotion
        self.announcesPositionChanges = announcesPositionChanges
    }

    public static let `default` = ReaderAccessibilitySettings()

    private enum CodingKeys: String, CodingKey {
        case isVoiceOverEnabled
        case forceScrollWhenVoiceOverEnabled
        case prefersReducedMotion
        case announcesPositionChanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVoiceOverEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isVoiceOverEnabled
        ) ?? false
        forceScrollWhenVoiceOverEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .forceScrollWhenVoiceOverEnabled
        ) ?? true
        prefersReducedMotion = try container.decodeIfPresent(
            Bool.self,
            forKey: .prefersReducedMotion
        ) ?? false
        announcesPositionChanges = try container.decodeIfPresent(
            Bool.self,
            forKey: .announcesPositionChanges
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVoiceOverEnabled, forKey: .isVoiceOverEnabled)
        try container.encode(
            forceScrollWhenVoiceOverEnabled,
            forKey: .forceScrollWhenVoiceOverEnabled
        )
        try container.encode(prefersReducedMotion, forKey: .prefersReducedMotion)
        try container.encode(announcesPositionChanges, forKey: .announcesPositionChanges)
    }
}

public struct Locator: Sendable, Equatable, Hashable, Codable {
    public var sectionIndex: Int
    public var sectionHref: String?
    public var sectionProgression: Double
    public var totalProgression: Double
    public var anchor: String?
    public var cfi: String?
    public var textContext: TextContext?
    public var timestamp: Double?

    public init(
        sectionIndex: Int,
        sectionHref: String?,
        sectionProgression: Double,
        totalProgression: Double,
        anchor: String?,
        cfi: String?,
        textContext: TextContext?,
        timestamp: Double? = nil
    ) {
        self.sectionIndex = max(sectionIndex, 0)
        self.sectionHref = sectionHref
        self.sectionProgression = min(max(sectionProgression, 0), 1)
        self.totalProgression = min(max(totalProgression, 0), 1)
        self.anchor = anchor
        self.cfi = cfi
        self.textContext = textContext
        self.timestamp = timestamp
    }

    public var position: Position {
        Position(
            spineIndex: sectionIndex,
            progression: sectionProgression,
            cfi: cfi,
            fragment: anchor,
            textContext: textContext,
            timestamp: timestamp
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
        textContext: nil,
        timestamp: nil
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

public struct ReaderSelection: Sendable, Equatable {
    public var range: SelectionRange
    public var text: String
    public var locator: Locator

    public init(range: SelectionRange, text: String, locator: Locator) {
        self.range = range
        self.text = text
        self.locator = locator
    }
}

public enum NavigatorEvent: Sendable, Equatable {
    case ready
    case locatorChanged(Locator)
    case paginationChanged(PageMap)
    case selectionChanged(ReaderSelection)
    case contentHeightChanged(Double)
    case historyChanged(canGoBack: Bool, canGoForward: Bool)
    case readingModeChanged(ReadingMode)
    case preferencesChanged(ReaderPreferences)
    case accessibilityChanged(ReaderAccessibilitySettings)
    case linkActivated(url: URL, kind: LinkKind, action: LinkAction)
    case decorationTapped(DecorationTapEvent)
    case bridgeMessage(name: String, payload: BridgeValue)
    case error(BookError)
}

@MainActor
public protocol Navigator: AnyObject {
    var events: AsyncStream<NavigatorEvent> { get }

    func currentLocator() async -> Locator
    func go(to locator: Locator) async throws
    func go(to navigationItem: TOCNode) async throws
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
    func callBridgeCommand(_ name: String, payload: BridgeValue) async throws -> BridgeValue
}

public extension Book {
    func locator(for position: Position) -> Locator {
        let sectionCount = max(readingOrder.count, 1)
        let index = min(max(position.spineIndex, 0), sectionCount - 1)
        let sectionProgression = min(max(position.progression, 0), 1)
        let total: Double
        if presentation.layout == .audiobook, !readingOrder.isEmpty {
            let durations = readingOrder.map { chapter -> Double in
                let begin = chapter.audio?.clipBegin ?? 0
                if let end = chapter.audio?.clipEnd, end >= begin {
                    return end - begin
                }
                return max(chapter.audio?.duration ?? 0, 0)
            }
            let totalDuration = durations.reduce(0, +)
            if totalDuration > 0 {
                let preceding = durations.prefix(index).reduce(0, +)
                let begin = readingOrder[index].audio?.clipBegin ?? 0
                let elapsed = position.timestamp.map { $0 - begin }
                    ?? sectionProgression * durations[index]
                let local = min(max(elapsed, 0), durations[index])
                total = min(max((preceding + local) / totalDuration, 0), 1)
            } else {
                total = min(max((Double(index) + sectionProgression) / Double(sectionCount), 0), 1)
            }
        } else {
            total = min(max((Double(index) + sectionProgression) / Double(sectionCount), 0), 1)
        }
        let href = readingOrder.indices.contains(index) ? readingOrder[index].href : nil

        return Locator(
            sectionIndex: index,
            sectionHref: href,
            sectionProgression: sectionProgression,
            totalProgression: total,
            anchor: position.fragment,
            cfi: position.cfi,
            textContext: position.textContext,
            timestamp: position.timestamp
        )
    }

    func locator(
        forNavigationHref rawHref: String,
        relativeTo currentChapterHref: String? = nil
    ) -> Locator? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let path: String
        let fragment: String?
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            fragment = url.fragment?.removingPercentEncoding ?? url.fragment
            if scheme != "bookkit" {
                let target = navigationResourceKey(trimmed)
                guard let index = readingOrder.firstIndex(where: {
                    navigationResourceKey($0.href) == target
                }) else {
                    return nil
                }
                return locator(for: navigationPosition(index: index, fragment: fragment))
            }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path = parts.first.map(String.init) ?? ""
            let rawFragment = parts.count > 1 ? String(parts[1]) : nil
            fragment = rawFragment?.removingPercentEncoding ?? rawFragment
        }

        let currentPath = currentChapterHref.map(normalizeNavigationPath) ?? ""
        var candidates: [String] = []
        if path.isEmpty || path == "current" {
            if !currentPath.isEmpty {
                candidates.append(currentPath)
            }
        } else {
            let normalizedPath = normalizeNavigationPath(path)
            candidates.append(normalizedPath)

            let currentDirectory = normalizeNavigationPath(
                (currentPath as NSString).deletingLastPathComponent
            )
            if !currentDirectory.isEmpty {
                candidates.append(
                    normalizeNavigationPath(
                        (currentDirectory as NSString).appendingPathComponent(path)
                    )
                )
            }
        }

        for candidate in candidates where !candidate.isEmpty {
            if let index = readingOrder.firstIndex(where: {
                normalizeNavigationPath($0.href) == candidate
            }) {
                return locator(for: navigationPosition(index: index, fragment: fragment))
            }

            if let index = readingOrder.firstIndex(where: {
                let href = normalizeNavigationPath($0.href)
                return href.hasSuffix("/" + candidate) || candidate.hasSuffix("/" + href)
            }) {
                return locator(for: navigationPosition(index: index, fragment: fragment))
            }
        }

        return nil
    }

    private func navigationResourceKey(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? raw
        }
        components.fragment = nil
        return components.string ?? raw
    }

    private func navigationPosition(index: Int, fragment: String?) -> Position {
        guard presentation.layout == .audiobook,
              readingOrder.indices.contains(index)
        else {
            return Position(spineIndex: index, progression: 0, fragment: fragment)
        }

        let audio = readingOrder[index].audio
        let begin = audio?.clipBegin ?? 0
        let duration: Double
        if let end = audio?.clipEnd, end >= begin {
            duration = end - begin
        } else {
            duration = max(audio?.duration ?? 0, 0)
        }
        let requested = fragment.flatMap(mediaFragmentTimestamp) ?? begin
        let upper = duration > 0 ? begin + duration : max(requested, begin)
        let timestamp = min(max(requested, begin), upper)
        let progression = duration > 0 ? (timestamp - begin) / duration : 0
        return Position(
            spineIndex: index,
            progression: min(max(progression, 0), 1),
            fragment: fragment,
            timestamp: timestamp
        )
    }

    private func mediaFragmentTimestamp(_ fragment: String) -> Double? {
        var value = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("t=") else { return nil }
        value.removeFirst(2)
        value = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? value
        if value.lowercased().hasPrefix("npt:") {
            value.removeFirst(4)
        }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let components = value.split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(components.count),
              components.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            return nil
        }
        return components.reversed().enumerated().reduce(0) { result, item in
            result + item.element * pow(60, Double(item.offset))
        }
    }

    private func normalizeNavigationPath(_ raw: String) -> String {
        let noFragment = raw.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? raw
        let noQuery = noFragment.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? noFragment
        let decoded = (noQuery.removingPercentEncoding ?? noQuery)
            .replacingOccurrences(of: "\\", with: "/")

        var components: [String] = []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(String(component))
        }
        return components.joined(separator: "/")
    }
}
