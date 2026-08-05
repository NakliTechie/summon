import Foundation

/// Attribution tag carried on every action into the journal (invariant 8).
///
/// Roles: user · agent · system · extension (vision §2).
public enum ActorTag: Sendable, Hashable, Codable, Equatable {
    case user
    case agent
    case system
    /// Extension actor — journal label `ext:<id>` (vision §2).
    case ext(id: String)

    /// Stable journal label: `user` | `agent` | `system` | `ext:<id>`.
    public var journalLabel: String {
        switch self {
        case .user: return "user"
        case .agent: return "agent"
        case .system: return "system"
        case .ext(let id): return "ext:\(id)"
        }
    }

    public init(journalLabel: String) throws {
        switch journalLabel {
        case "user": self = .user
        case "agent": self = .agent
        case "system": self = .system
        case let s where s.hasPrefix("ext:"):
            let id = String(s.dropFirst(4))
            guard !id.isEmpty else {
                throw CoreError.invalidActor(journalLabel)
            }
            self = .ext(id: id)
        default:
            throw CoreError.invalidActor(journalLabel)
        }
    }

    /// Actors accepted from the public CLI flag. Internal roles are never caller-selectable.
    public init(cliLabel: String) throws {
        switch cliLabel {
        case "user": self = .user
        case "agent": self = .agent
        default: throw CoreError.invalidActor(cliLabel)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let label = try container.decode(String.self)
        self = try ActorTag(journalLabel: label)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(journalLabel)
    }
}
