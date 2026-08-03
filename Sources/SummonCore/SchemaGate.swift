import Foundation

/// One ingress for every external payload (invariant 6).
///
/// Validates and decodes extension-facing / CLI-JSON / socket messages into
/// typed `CoreAction` values before they reach the bus. The door supplies the
/// `ActorTag`; SchemaGate never trusts an actor claim inside the payload.
public struct SchemaGate: Sendable {
    public static let schemaVersion = 1

    public init() {}

    /// Wire format for external actions (JSON).
    ///
    /// ```json
    /// { "v": 1, "action": "settings.set", "key": "theme", "value": "dark" }
    /// ```
    public struct ExternalActionDocument: Codable, Equatable, Sendable {
        public let v: Int
        public let action: String
        public let key: String?
        public let value: JSONValue?

        public init(v: Int = SchemaGate.schemaVersion, action: String, key: String? = nil, value: JSONValue? = nil) {
            self.v = v
            self.action = action
            self.key = key
            self.value = value
        }
    }

    /// Decode and validate raw external JSON into a `CoreAction`.
    public func decodeAction(from data: Data) throws -> CoreAction {
        let doc: ExternalActionDocument
        do {
            doc = try JSONDecoder().decode(ExternalActionDocument.self, from: data)
        } catch {
            throw CoreError.schemaValidation("malformed JSON: \(error.localizedDescription)")
        }
        return try decodeAction(document: doc)
    }

    public func decodeAction(document doc: ExternalActionDocument) throws -> CoreAction {
        guard doc.v == Self.schemaVersion else {
            throw CoreError.schemaValidation(
                "unsupported schema version \(doc.v); expected \(Self.schemaVersion)"
            )
        }
        switch doc.action {
        case "settings.set":
            guard let key = doc.key, !key.isEmpty else {
                throw CoreError.schemaValidation("settings.set requires non-empty key")
            }
            guard let value = doc.value else {
                throw CoreError.schemaValidation("settings.set requires value")
            }
            return .settingsSet(key: key, value: value)
        case "settings.delete":
            guard let key = doc.key, !key.isEmpty else {
                throw CoreError.schemaValidation("settings.delete requires non-empty key")
            }
            return .settingsDelete(key: key)
        default:
            throw CoreError.unknownAction(doc.action)
        }
    }

    /// Build an envelope from external data + door-supplied actor.
    public func envelope(
        from data: Data,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionEnvelope {
        let action = try decodeAction(from: data)
        return ActionEnvelope(id: id, actor: actor, timestamp: timestamp, action: action)
    }

    /// Encode a CoreAction to the external document form (for fixtures / CLI JSON).
    public func encodeDocument(_ action: CoreAction) throws -> Data {
        let doc: ExternalActionDocument
        switch action {
        case .settingsSet(let key, let value):
            doc = ExternalActionDocument(action: "settings.set", key: key, value: value)
        case .settingsDelete(let key):
            doc = ExternalActionDocument(action: "settings.delete", key: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(doc)
    }
}
