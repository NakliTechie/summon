import Foundation

/// Typed actions that enter the single action bus (invariant 7).
///
/// Chunk-1 surface is the settings store. Modules append cases as they land;
/// every door (UI, CLI, socket, shim) dispatches the same enum.
public enum CoreAction: Sendable, Hashable, Codable, Equatable {
    /// Set a settings key to a JSON-compatible value.
    case settingsSet(key: String, value: JSONValue)
    /// Remove a settings key (no-op if absent).
    case settingsDelete(key: String)

    public var name: String {
        switch self {
        case .settingsSet: return "settings.set"
        case .settingsDelete: return "settings.delete"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case key
        case value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "settings.set":
            let key = try c.decode(String.self, forKey: .key)
            let value = try c.decode(JSONValue.self, forKey: .value)
            self = .settingsSet(key: key, value: value)
        case "settings.delete":
            let key = try c.decode(String.self, forKey: .key)
            self = .settingsDelete(key: key)
        default:
            throw CoreError.unknownAction(name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        switch self {
        case .settingsSet(let key, let value):
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        case .settingsDelete(let key):
            try c.encode(key, forKey: .key)
        }
    }
}
