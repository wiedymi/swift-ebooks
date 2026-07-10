import CoreFoundation
import Foundation

/// A recursively typed JSON value used at BookKit's JavaScript boundary.
public indirect enum BridgeValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BridgeValue])
    case object([String: BridgeValue])

    public init?(foundationValue value: Any) {
        switch value {
        case is NSNull:
            self = .null

        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }

        case let value as String:
            self = .string(value)

        case let values as [Any]:
            var converted: [BridgeValue] = []
            converted.reserveCapacity(values.count)
            for value in values {
                guard let item = BridgeValue(foundationValue: value) else {
                    return nil
                }
                converted.append(item)
            }
            self = .array(converted)

        case let values as [String: Any]:
            var converted: [String: BridgeValue] = [:]
            converted.reserveCapacity(values.count)
            for (key, value) in values {
                guard let item = BridgeValue(foundationValue: value) else {
                    return nil
                }
                converted[key] = item
            }
            self = .object(converted)

        default:
            return nil
        }
    }

    public var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.foundationValue)
        case let .object(values):
            return values.mapValues(\.foundationValue)
        }
    }
}

/// A script installed after BookKit's private bootstrap in the isolated app world.
public struct ReflowScriptPlugin: Sendable, Equatable, Hashable {
    public var identifier: String
    public var source: String

    public init(identifier: String, source: String) {
        self.identifier = identifier
        self.source = source
    }
}
