import Foundation

/// Typed actions that enter the single action bus (invariant 7).
///
/// Every door (UI, CLI, socket, shim) dispatches the same enum.
public enum CoreAction: Sendable, Hashable, Codable, Equatable {
    case settingsSet(key: String, value: JSONValue)
    case settingsDelete(key: String)
    case snippetUpsert(id: String, name: String, body: String, keyword: String?)
    case snippetDelete(id: String)

    public var name: String {
        switch self {
        case .settingsSet: return "settings.set"
        case .settingsDelete: return "settings.delete"
        case .snippetUpsert: return "snippet.upsert"
        case .snippetDelete: return "snippet.delete"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case key
        case value
        case id
        case body
        case keyword
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
        case "snippet.upsert":
            let id = try c.decode(String.self, forKey: .id)
            let key = try c.decode(String.self, forKey: .key) // name stored under key for brevity
            let body = try c.decode(String.self, forKey: .body)
            let keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
            self = .snippetUpsert(id: id, name: key, body: body, keyword: keyword)
        case "snippet.delete":
            let id = try c.decode(String.self, forKey: .id)
            self = .snippetDelete(id: id)
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
        case .snippetUpsert(let id, let name, let body, let keyword):
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .key)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(keyword, forKey: .keyword)
        case .snippetDelete(let id):
            try c.encode(id, forKey: .id)
        }
    }
}
