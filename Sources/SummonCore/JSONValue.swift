import Foundation

/// JSON-compatible value used in settings, exports, and external payloads.
public enum JSONValue: Sendable, Hashable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .number(Double(i))
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let n):
            if n.rounded() == n, n >= Double(Int64.min), n <= Double(Int64.max) {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }

    /// Parse a CLI token into a JSONValue (bool / number / string).
    public static func parseCLI(_ raw: String) -> JSONValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw == "null" { return .null }
        if let i = Int64(raw) { return .number(Double(i)) }
        if let d = Double(raw), raw.contains(".") { return .number(d) }
        return .string(raw)
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n, n >= Double(Int64.min), n <= Double(Int64.max) {
                return String(Int64(n))
            }
            return String(n)
        case .string(let s): return s
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let s = String(data: data, encoding: .utf8) else {
                return "<json>"
            }
            return s
        }
    }
}
