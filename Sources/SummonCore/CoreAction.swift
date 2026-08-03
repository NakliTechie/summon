import Foundation

/// Typed actions that enter the single action bus (invariant 7).
public enum CoreAction: Sendable, Hashable, Codable, Equatable {
    case settingsSet(key: String, value: JSONValue)
    case settingsDelete(key: String)
    case snippetUpsert(id: String, name: String, body: String, keyword: String?)
    case snippetDelete(id: String)
    case clipboardIngest(id: String, text: String, sourceApp: String?, createdAt: Date, pinned: Bool)
    case clipboardDelete(id: String)
    case clipboardPin(id: String, pinned: Bool)
    case clipboardClearUnpinned
    case quicklinkUpsert(id: String, name: String, url: String, keyword: String?)
    case quicklinkDelete(id: String)
    /// Side-effecting module invoke (open/reveal/copy). Journaled; applied via ModuleExecuting.
    case moduleRun(name: String, targetID: String, path: String?, payload: [String: JSONValue])

    public var name: String {
        switch self {
        case .settingsSet: return "settings.set"
        case .settingsDelete: return "settings.delete"
        case .snippetUpsert: return "snippet.upsert"
        case .snippetDelete: return "snippet.delete"
        case .clipboardIngest: return "clipboard.ingest"
        case .clipboardDelete: return "clipboard.delete"
        case .clipboardPin: return "clipboard.pin"
        case .clipboardClearUnpinned: return "clipboard.clearUnpinned"
        case .quicklinkUpsert: return "quicklink.upsert"
        case .quicklinkDelete: return "quicklink.delete"
        case .moduleRun: return "module.run"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, key, value, id, body, keyword, text, sourceApp, createdAt, pinned, url
        case targetID, path, payload, module
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "settings.set":
            self = .settingsSet(
                key: try c.decode(String.self, forKey: .key),
                value: try c.decode(JSONValue.self, forKey: .value)
            )
        case "settings.delete":
            self = .settingsDelete(key: try c.decode(String.self, forKey: .key))
        case "snippet.upsert":
            self = .snippetUpsert(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .key),
                body: try c.decode(String.self, forKey: .body),
                keyword: try c.decodeIfPresent(String.self, forKey: .keyword)
            )
        case "snippet.delete":
            self = .snippetDelete(id: try c.decode(String.self, forKey: .id))
        case "clipboard.ingest":
            let createdAt: Date
            if let s = try c.decodeIfPresent(String.self, forKey: .createdAt),
               let d = ISO8601DateFormatter().date(from: s) {
                createdAt = d
            } else {
                createdAt = Date()
            }
            self = .clipboardIngest(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                sourceApp: try c.decodeIfPresent(String.self, forKey: .sourceApp),
                createdAt: createdAt,
                pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            )
        case "clipboard.delete":
            self = .clipboardDelete(id: try c.decode(String.self, forKey: .id))
        case "clipboard.pin":
            self = .clipboardPin(
                id: try c.decode(String.self, forKey: .id),
                pinned: try c.decode(Bool.self, forKey: .pinned)
            )
        case "clipboard.clearUnpinned":
            self = .clipboardClearUnpinned
        case "quicklink.upsert":
            self = .quicklinkUpsert(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .key),
                url: try c.decode(String.self, forKey: .url),
                keyword: try c.decodeIfPresent(String.self, forKey: .keyword)
            )
        case "quicklink.delete":
            self = .quicklinkDelete(id: try c.decode(String.self, forKey: .id))
        case "module.run":
            self = .moduleRun(
                name: try c.decode(String.self, forKey: .module),
                targetID: try c.decode(String.self, forKey: .targetID),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                payload: try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
            )
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
        case .clipboardIngest(let id, let text, let sourceApp, let createdAt, let pinned):
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
            try c.encode(ISO8601DateFormatter().string(from: createdAt), forKey: .createdAt)
            try c.encode(pinned, forKey: .pinned)
        case .clipboardDelete(let id):
            try c.encode(id, forKey: .id)
        case .clipboardPin(let id, let pinned):
            try c.encode(id, forKey: .id)
            try c.encode(pinned, forKey: .pinned)
        case .clipboardClearUnpinned:
            break
        case .quicklinkUpsert(let id, let name, let url, let keyword):
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .key)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(keyword, forKey: .keyword)
        case .quicklinkDelete(let id):
            try c.encode(id, forKey: .id)
        case .moduleRun(let module, let targetID, let path, let payload):
            try c.encode(module, forKey: .module)
            try c.encode(targetID, forKey: .targetID)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(payload, forKey: .payload)
        }
    }
}
