import Foundation

enum ReflowBridgeEvent: Sendable, Equatable {
    case ready
    case paginationChanged(pageCount: Int, chapterProgressMap: [Int: [Double]])
    case positionChanged(spineIndex: Int, progression: Double, cfi: String?, anchor: String?)
    case linkTapped(url: URL, kind: LinkKind)
    case decorationTapped(id: String, group: DecorationGroup)
    case selectionChanged(range: SelectionRange, text: String)
    case contentHeightChanged(Double)
    case custom(name: String, payload: BridgeValue)
}

@MainActor
protocol ReflowBridge: AnyObject {
    var events: AsyncStream<ReflowBridgeEvent> { get }

    func setContent(html: String, css: String, viewport: Viewport) async throws
    func goToAnchor(_ id: String) async throws
    func goToProgression(_ value: Double) async throws
    func setReadingMode(_ mode: ReadingMode) async throws
    func setTheme(_ theme: Theme) async throws
    func setTypography(_ typography: Typography) async throws
    func setDecorations(_ decorations: [Decoration]) async throws
    func setAccessibility(_ settings: ReaderAccessibilitySettings) async throws
    func setPublicationLayout(_ layout: PublicationLayout) async throws
    func setNetworkAccessAllowed(_ allowed: Bool) async throws
    func callPlugin(_ name: String, payload: BridgeValue) async throws -> BridgeValue
    func measurePages() async throws
}

extension ReflowBridge {
    func setAccessibility(_: ReaderAccessibilitySettings) async throws {}
    func setPublicationLayout(_: PublicationLayout) async throws {}
    func setNetworkAccessAllowed(_: Bool) async throws {}

    func callPlugin(_: String, payload _: BridgeValue) async throws -> BridgeValue {
        throw BookError.renderingFailed("This reflow bridge does not support custom commands")
    }
}

enum BridgeMessageValidator {
    public static func decode(body: Any) -> ReflowBridgeEvent? {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String
        else {
            return nil
        }

        switch type {
        case "ready":
            return .ready

        case "paginationChanged":
            guard let pageCount = numericInt(dict["pageCount"]), pageCount > 0 else {
                return nil
            }
            let chapterProgressMap = decodeProgressMap(dict["chapterProgressMap"])
            return .paginationChanged(pageCount: pageCount, chapterProgressMap: chapterProgressMap)

        case "positionChanged":
            guard let spineIndex = numericInt(dict["spineIndex"]),
                  let progression = numericDouble(dict["progression"])
            else {
                return nil
            }
            let clampedProgression = min(max(progression, 0), 1)
            let cfi = dict["cfi"] as? String
            let anchor = dict["anchor"] as? String
            return .positionChanged(spineIndex: max(spineIndex, 0), progression: clampedProgression, cfi: cfi, anchor: anchor)

        case "linkTapped":
            guard let raw = dict["url"] as? String,
                  !raw.isEmpty,
                  let kindRaw = dict["kind"] as? String
            else {
                return nil
            }
            let base = URL(string: "bookkit://chapter/current")!
            guard let url = URL(string: raw, relativeTo: base) else {
                return nil
            }
            let kind = LinkKind(rawValue: kindRaw) ?? .unsupported
            return .linkTapped(url: url, kind: kind)

        case "decorationTapped":
            guard let id = dict["id"] as? String,
                  !id.isEmpty,
                  let groupRaw = dict["group"] as? String,
                  let group = DecorationGroup(rawValue: groupRaw)
            else {
                return nil
            }
            return .decorationTapped(id: id, group: group)

        case "selectionChanged":
            guard let start = numericInt(dict["start"]),
                  let end = numericInt(dict["end"]),
                  let text = dict["text"] as? String
            else {
                return nil
            }
            return .selectionChanged(range: SelectionRange(start: start, end: end), text: text)

        case "contentHeightChanged":
            guard let value = numericDouble(dict["value"]) else {
                return nil
            }
            return .contentHeightChanged(max(value, 0))

        case "custom":
            guard let name = dict["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let payload: BridgeValue
            if let rawPayload = dict["payload"] {
                guard let decoded = BridgeValue(foundationValue: rawPayload) else {
                    return nil
                }
                payload = decoded
            } else {
                payload = .null
            }
            return .custom(name: name, payload: payload)

        default:
            return nil
        }
    }

    private static func decodeProgressMap(_ input: Any?) -> [Int: [Double]] {
        guard let rawMap = input as? [String: Any] else {
            return [:]
        }

        var output: [Int: [Double]] = [:]
        for (key, value) in rawMap {
            guard let idx = Int(key), idx >= 0 else {
                continue
            }

            let values: [Double]
            if let doubles = value as? [Double] {
                values = doubles
            } else if let numbers = value as? [NSNumber] {
                values = numbers.map(\.doubleValue)
            } else if let anyValues = value as? [Any] {
                values = anyValues.compactMap(numericDouble)
            } else {
                values = []
            }

            output[idx] = values.map { min(max($0, 0), 1) }
        }
        return output
    }

    private static func numericInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let str = value as? String { return Int(str) }
        return nil
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let number = value as? NSNumber { return number.doubleValue }
        if let str = value as? String { return Double(str) }
        return nil
    }
}
