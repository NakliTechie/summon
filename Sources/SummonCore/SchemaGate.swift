import Foundation

/// One ingress for every external payload (invariant 6).
public struct SchemaGate: Sendable {
    public static let schemaVersion = 1

    public init() {}

    public struct ExternalActionDocument: Codable, Equatable, Sendable {
        public let v: Int
        public let action: String
        public let key: String?
        public let value: JSONValue?
        public let id: String?
        public let body: String?
        public let keyword: String?
        public let text: String?
        public let url: String?

        public init(
            v: Int = SchemaGate.schemaVersion,
            action: String,
            key: String? = nil,
            value: JSONValue? = nil,
            id: String? = nil,
            body: String? = nil,
            keyword: String? = nil,
            text: String? = nil,
            url: String? = nil
        ) {
            self.v = v
            self.action = action
            self.key = key
            self.value = value
            self.id = id
            self.body = body
            self.keyword = keyword
            self.text = text
            self.url = url
        }
    }

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
        case "snippet.upsert":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("snippet.upsert requires id")
            }
            guard let name = doc.key, !name.isEmpty else {
                throw CoreError.schemaValidation("snippet.upsert requires key (name)")
            }
            guard let body = doc.body else {
                throw CoreError.schemaValidation("snippet.upsert requires body")
            }
            return .snippetUpsert(id: id, name: name, body: body, keyword: doc.keyword)
        case "snippet.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("snippet.delete requires id")
            }
            return .snippetDelete(id: id)
        case "quicklink.upsert":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("quicklink.upsert requires id")
            }
            guard let name = doc.key, !name.isEmpty else {
                throw CoreError.schemaValidation("quicklink.upsert requires key (name)")
            }
            guard let url = doc.url, !url.isEmpty else {
                throw CoreError.schemaValidation("quicklink.upsert requires url")
            }
            return .quicklinkUpsert(id: id, name: name, url: url, keyword: doc.keyword)
        case "quicklink.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("quicklink.delete requires id")
            }
            return .quicklinkDelete(id: id)
        case "clipboard.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("clipboard.delete requires id")
            }
            return .clipboardDelete(id: id)
        default:
            throw CoreError.unknownAction(doc.action)
        }
    }

    public func envelope(
        from data: Data,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionEnvelope {
        let action = try decodeAction(from: data)
        return ActionEnvelope(id: id, actor: actor, timestamp: timestamp, action: action)
    }

    public func encodeDocument(_ action: CoreAction) throws -> Data {
        let doc: ExternalActionDocument
        switch action {
        case .settingsSet(let key, let value):
            doc = ExternalActionDocument(action: "settings.set", key: key, value: value)
        case .settingsDelete(let key):
            doc = ExternalActionDocument(action: "settings.delete", key: key)
        case .snippetUpsert(let id, let name, let body, let keyword):
            doc = ExternalActionDocument(
                action: "snippet.upsert",
                key: name,
                id: id,
                body: body,
                keyword: keyword
            )
        case .snippetDelete(let id):
            doc = ExternalActionDocument(action: "snippet.delete", id: id)
        case .quicklinkUpsert(let id, let name, let url, let keyword):
            doc = ExternalActionDocument(
                action: "quicklink.upsert",
                key: name,
                id: id,
                keyword: keyword,
                url: url
            )
        case .quicklinkDelete(let id):
            doc = ExternalActionDocument(action: "quicklink.delete", id: id)
        case .clipboardDelete(let id):
            doc = ExternalActionDocument(action: "clipboard.delete", id: id)
        default:
            throw CoreError.schemaValidation("action \(action.name) is not external-wireable")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(doc)
    }
}
