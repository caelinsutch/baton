import Foundation

/// A minimal JSON tree. The MCP boundary needs dynamic shapes, and this keeps
/// `Any` out of the rest of the code.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Reads

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["true", "yes", "1"].contains(value.lowercased())
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        let value = dictionary[key]
        return value == .null ? nil : value
    }

    // MARK: - Serialisation

    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return from(any: object)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public func serialized() -> Data {
        (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])) ?? Data("null".utf8)
    }

    public func compactString() -> String {
        String(data: serialized(), encoding: .utf8) ?? "null"
    }

    public func prettyString() -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: anyValue,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func from(any object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let value as Bool where type(of: object) == type(of: NSNumber(value: true)):
            return .bool(value)
        case let value as NSNumber:
            // NSNumber hides the bool case. Compare the ObjC type encoding.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map { from(any: $0) })
        case let value as [String: Any]:
            return .object(value.mapValues { from(any: $0) })
        default:
            return .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // Keep whole numbers whole so ids and counts do not gain a ".0".
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                return Int(value)
            }
            return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// Builds an object and drops the nil entries, so optional fields vanish
    /// instead of turning into JSON nulls.
    public static func object(compacting pairs: [String: JSONValue?]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in pairs {
            if let value, value != .null { result[key] = value }
        }
        return .object(result)
    }

    public static func string(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }

    /// Encodes any `Encodable` through `JSONSerialization`.
    public static func encode<T: Encodable>(_ value: T, encoder: JSONEncoder = defaultEncoder) -> JSONValue {
        guard let data = try? encoder.encode(value), let parsed = try? parse(data) else { return .null }
        return parsed
    }

    public static let defaultEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
