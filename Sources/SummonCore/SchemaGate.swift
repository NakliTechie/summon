import Foundation

/// One ingress for every external payload (invariant 6).
public struct SchemaGate: Sendable {
    public static let schemaVersion = 1
    public static let maximumDocumentBytes = 256 * 1024
    public static let maximumNestingDepth = 16
    public static let maximumStringBytes = 64 * 1024
    public static let maximumURLBytes = 4 * 1024

    private static let maximumIdentifierBytes = 256
    private static let maximumNameBytes = 512
    private static let maximumCollectionEntries = 4_096
    private static let maximumJSONNodes = 4_096
    private static let maximumImportJSONNodes = 32_768
    public static let maximumImportDocumentBytes = 40 * 1_024 * 1_024

    public init() {}

    /// Applies the common external-document limits and rejects unknown fields.
    /// `arrayObjectFields` names root arrays whose members must be objects with
    /// the supplied field set.
    public func preflightJSONObject(
        _ data: Data,
        allowedRootFields: Set<String>,
        arrayObjectFields: [String: Set<String>] = [:]
    ) throws {
        let object = try Self.decodeJSONObject(from: data, allowedKeys: allowedRootFields)
        for (field, allowedFields) in arrayObjectFields {
            guard let value = object[field] else { continue }
            guard let array = value as? [Any] else {
                throw CoreError.schemaValidation("\(field) must be an array")
            }
            for (index, element) in array.enumerated() {
                guard let child = element as? [String: Any] else {
                    throw CoreError.schemaValidation("\(field)[\(index)] must be an object")
                }
                do {
                    try Self.rejectUnknownFields(in: child, allowed: allowedFields)
                } catch {
                    throw CoreError.schemaValidation("\(field)[\(index)]: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Applies bounded parsing and exact field policy to a store import before Codable decoding.
    public func preflightStoreExportBundle(_ data: Data) throws {
        guard data.count <= Self.maximumImportDocumentBytes else {
            throw CoreError.schemaValidation("import document exceeds byte limit")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CoreError.schemaValidation("malformed import JSON: \(error.localizedDescription)")
        }
        guard let root = value as? [String: Any] else {
            throw CoreError.schemaValidation("import document must be an object")
        }
        var nodeCount = 0
        try Self.validateImportJSONValue(root, depth: 0, nodeCount: &nodeCount)
        try Self.rejectUnknownFields(
            in: root,
            allowed: [
                "version", "exportedAt", "snapshot", "aliases", "favorites",
                "clipboardIgnore", "frecency", "history", "stagedProposals",
                "journal", "journalTotalCount", "includeClipboard",
            ]
        )
        guard let snapshot = root["snapshot"] as? [String: Any] else {
            throw CoreError.schemaValidation("snapshot must be an object")
        }
        try Self.rejectUnknownFields(
            in: snapshot,
            allowed: ["schemaVersion", "settings", "snippets", "clipboard", "quicklinks"]
        )
        try Self.validateImportSettings(snapshot["settings"])
        try Self.validateImportArray(
            snapshot["snippets"],
            field: "snapshot.snippets",
            allowed: ["id", "name", "body", "keyword"]
        )
        try Self.validateImportArray(
            snapshot["clipboard"],
            field: "snapshot.clipboard",
            allowed: [
                "id", "text", "sourceApp", "createdAt", "isPinned",
                "contentKind", "flavor", "data",
            ]
        )
        try Self.validateImportArray(
            snapshot["quicklinks"],
            field: "snapshot.quicklinks",
            allowed: ["id", "name", "url", "keyword"]
        )
        try Self.validateImportArray(
            root["aliases"],
            field: "aliases",
            allowed: ["keyword", "targetResultID", "title", "kind", "path", "payload"]
        )
        try Self.validateImportArray(
            root["favorites"],
            field: "favorites",
            allowed: ["id", "resultID", "title", "kind", "path"]
        )
        try Self.validateImportStringArray(root["clipboardIgnore"], field: "clipboardIgnore")
        try Self.validateImportArray(
            root["frecency"],
            field: "frecency",
            allowed: ["resultID", "count", "lastUsed", "title", "kind", "path", "payload"]
        )
        try Self.validateImportArray(
            root["history"],
            field: "history",
            allowed: ["id", "query", "createdAt"]
        )
        try Self.validateImportArray(
            root["stagedProposals"],
            field: "stagedProposals",
            allowed: [
                "id", "createdAt", "rung", "prompt", "output",
                "egressSummary", "state", "failureReason",
            ]
        )
        try Self.validateImportArray(
            root["journal"],
            field: "journal",
            allowed: ["seq", "id", "actor", "timestamp", "actionName", "outcome"]
        )
    }

    private static func validateImportStringArray(_ value: Any?, field: String) throws {
        guard let values = value as? [Any] else {
            throw CoreError.schemaValidation("\(field) must be an array")
        }
        guard values.count <= maximumCollectionEntries else {
            throw CoreError.schemaValidation("\(field) exceeds entry limit")
        }
        for (index, value) in values.enumerated() {
            guard let string = value as? String else {
                throw CoreError.schemaValidation("\(field)[\(index)] must be a string")
            }
            try validate(
                string,
                field: "\(field)[\(index)]",
                maximumBytes: maximumIdentifierBytes
            )
        }
    }

    private static func validateImportSettings(_ value: Any?) throws {
        guard let settings = value as? [String: Any] else {
            throw CoreError.schemaValidation("snapshot.settings must be an object")
        }
        for (key, settingValue) in settings {
            try validate(key, field: "settings key", maximumBytes: maximumIdentifierBytes)
            try validateImportScalarStrings(settingValue, field: "settings.\(key)")
        }
    }

    private static func validateImportArray(
        _ value: Any?,
        field: String,
        allowed: Set<String>
    ) throws {
        guard let array = value as? [Any] else {
            throw CoreError.schemaValidation("\(field) must be an array")
        }
        guard array.count <= maximumCollectionEntries else {
            throw CoreError.schemaValidation("\(field) exceeds entry limit")
        }
        for (index, element) in array.enumerated() {
            guard let object = element as? [String: Any] else {
                throw CoreError.schemaValidation("\(field)[\(index)] must be an object")
            }
            do {
                try rejectUnknownFields(in: object, allowed: allowed)
                try validateImportObjectFields(object, field: field)
                for (key, child) in object where key != "data" {
                    try validateImportScalarStrings(child, field: "\(field)[\(index)].\(key)")
                }
            } catch {
                throw CoreError.schemaValidation(
                    "\(field)[\(index)]: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func validateImportObjectFields(
        _ object: [String: Any],
        field: String
    ) throws {
        func bounded(_ key: String, _ maximumBytes: Int) throws {
            guard let value = object[key], !(value is NSNull) else { return }
            guard let string = value as? String else {
                throw CoreError.schemaValidation("\(key) must be a string")
            }
            try validate(string, field: key, maximumBytes: maximumBytes)
        }
        switch field {
        case "snapshot.snippets":
            try bounded("id", maximumIdentifierBytes)
            try bounded("name", maximumNameBytes)
            try bounded("body", maximumStringBytes)
            try bounded("keyword", maximumIdentifierBytes)
        case "snapshot.clipboard":
            try bounded("id", maximumIdentifierBytes)
            try bounded("sourceApp", maximumNameBytes)
            try bounded("createdAt", maximumIdentifierBytes)
            try bounded("contentKind", maximumIdentifierBytes)
            try bounded("flavor", maximumIdentifierBytes)
        case "snapshot.quicklinks":
            try bounded("id", maximumIdentifierBytes)
            try bounded("name", maximumNameBytes)
            try bounded("url", maximumURLBytes)
            try bounded("keyword", maximumIdentifierBytes)
        case "aliases":
            try bounded("keyword", maximumIdentifierBytes)
            try bounded("targetResultID", maximumNameBytes)
            try bounded("title", maximumNameBytes)
            try bounded("kind", maximumIdentifierBytes)
            try bounded("path", maximumURLBytes)
        case "favorites":
            try bounded("id", maximumIdentifierBytes)
            try bounded("resultID", maximumNameBytes)
            try bounded("title", maximumNameBytes)
            try bounded("kind", maximumIdentifierBytes)
            try bounded("path", maximumURLBytes)
        case "frecency":
            try bounded("resultID", maximumNameBytes)
            try bounded("title", maximumNameBytes)
            try bounded("kind", maximumIdentifierBytes)
            try bounded("path", maximumURLBytes)
        case "history":
            try bounded("id", maximumIdentifierBytes)
            try bounded("query", maximumStringBytes)
            try bounded("createdAt", maximumIdentifierBytes)
        case "stagedProposals":
            try bounded("id", maximumIdentifierBytes)
            try bounded("createdAt", maximumIdentifierBytes)
            try bounded("rung", maximumIdentifierBytes)
            try bounded("prompt", StagedProposalStore.maximumPromptBytes)
            try bounded("output", StagedProposalStore.maximumOutputBytes)
            try bounded("egressSummary", StagedProposalStore.maximumEgressSummaryBytes)
            try bounded("state", maximumIdentifierBytes)
            try bounded("failureReason", StagedProposalStore.maximumFailureReasonBytes)
        case "journal":
            try bounded("id", maximumIdentifierBytes)
            try bounded("actor", maximumIdentifierBytes)
            try bounded("timestamp", maximumIdentifierBytes)
            try bounded("actionName", maximumIdentifierBytes)
            try bounded("outcome", maximumStringBytes)
        default:
            break
        }
    }

    private static func validateImportScalarStrings(_ value: Any, field: String) throws {
        switch value {
        case let string as String:
            try validate(string, field: field, maximumBytes: maximumStringBytes)
        case let array as [Any]:
            for child in array {
                try validateImportScalarStrings(child, field: field)
            }
        case let object as [String: Any]:
            for (key, child) in object {
                try validate(key, field: "\(field) key", maximumBytes: maximumIdentifierBytes)
                try validateImportScalarStrings(child, field: field)
            }
        default:
            break
        }
    }

    private static func validateImportJSONValue(
        _ value: Any,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= maximumNestingDepth else {
            throw CoreError.schemaValidation("import JSON nesting exceeds depth limit")
        }
        nodeCount += 1
        guard nodeCount <= maximumImportJSONNodes else {
            throw CoreError.schemaValidation("import JSON exceeds node limit")
        }
        switch value {
        case let string as String:
            guard string.utf8.count <= maximumImportDocumentBytes else {
                throw CoreError.schemaValidation("import string exceeds byte limit")
            }
        case let array as [Any]:
            guard array.count <= maximumCollectionEntries else {
                throw CoreError.schemaValidation("import array exceeds entry limit")
            }
            for child in array {
                try validateImportJSONValue(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        case let object as [String: Any]:
            guard object.count <= maximumCollectionEntries else {
                throw CoreError.schemaValidation("import object exceeds entry limit")
            }
            for (key, child) in object {
                try validate(key, field: "import object key", maximumBytes: maximumIdentifierBytes)
                try validateImportJSONValue(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        case let number as NSNumber:
            guard number.doubleValue.isFinite else {
                throw CoreError.schemaValidation("import number must be finite")
            }
        case is NSNull:
            return
        default:
            throw CoreError.schemaValidation("unsupported import JSON value")
        }
    }

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
        public let module: String?
        public let targetID: String?
        public let path: String?
        public let payload: [String: JSONValue]?

        public init(
            v: Int = SchemaGate.schemaVersion,
            action: String,
            key: String? = nil,
            value: JSONValue? = nil,
            id: String? = nil,
            body: String? = nil,
            keyword: String? = nil,
            text: String? = nil,
            url: String? = nil,
            module: String? = nil,
            targetID: String? = nil,
            path: String? = nil,
            payload: [String: JSONValue]? = nil
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
            self.module = module
            self.targetID = targetID
            self.path = path
            self.payload = payload
        }
    }

    public func decodeAction(from data: Data) throws -> CoreAction {
        let object = try Self.decodeJSONObject(from: data)
        try Self.validateActionFields(object)
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
            try Self.validate(key, field: "key", maximumBytes: Self.maximumIdentifierBytes)
            guard let value = doc.value else {
                throw CoreError.schemaValidation("settings.set requires value")
            }
            return .settingsSet(key: key, value: value)
        case "settings.delete":
            guard let key = doc.key, !key.isEmpty else {
                throw CoreError.schemaValidation("settings.delete requires non-empty key")
            }
            try Self.validate(key, field: "key", maximumBytes: Self.maximumIdentifierBytes)
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
            try Self.validate(id, field: "id", maximumBytes: Self.maximumIdentifierBytes)
            try Self.validate(name, field: "key", maximumBytes: Self.maximumNameBytes)
            try Self.validate(body, field: "body", maximumBytes: Self.maximumStringBytes)
            try Self.validateOptional(
                doc.keyword,
                field: "keyword",
                maximumBytes: Self.maximumIdentifierBytes
            )
            return .snippetUpsert(id: id, name: name, body: body, keyword: doc.keyword)
        case "snippet.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("snippet.delete requires id")
            }
            try Self.validate(id, field: "id", maximumBytes: Self.maximumIdentifierBytes)
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
            try Self.validate(id, field: "id", maximumBytes: Self.maximumIdentifierBytes)
            try Self.validate(name, field: "key", maximumBytes: Self.maximumNameBytes)
            try Self.validateOptional(
                doc.keyword,
                field: "keyword",
                maximumBytes: Self.maximumIdentifierBytes
            )
            try QuicklinkStore.validateURL(url)
            return .quicklinkUpsert(id: id, name: name, url: url, keyword: doc.keyword)
        case "quicklink.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("quicklink.delete requires id")
            }
            try Self.validate(id, field: "id", maximumBytes: Self.maximumIdentifierBytes)
            return .quicklinkDelete(id: id)
        case "clipboard.delete":
            guard let id = doc.id, !id.isEmpty else {
                throw CoreError.schemaValidation("clipboard.delete requires id")
            }
            try Self.validate(id, field: "id", maximumBytes: Self.maximumIdentifierBytes)
            return .clipboardDelete(id: id)
        case "module.run":
            guard let module = doc.module, !module.isEmpty else {
                throw CoreError.schemaValidation("module.run requires module")
            }
            guard let targetID = doc.targetID, !targetID.isEmpty else {
                throw CoreError.schemaValidation("module.run requires targetID")
            }
            try Self.validate(module, field: "module", maximumBytes: Self.maximumIdentifierBytes)
            try Self.validate(targetID, field: "targetID", maximumBytes: Self.maximumNameBytes)
            try Self.validateOptional(doc.path, field: "path", maximumBytes: Self.maximumURLBytes)
            if case .string(let url) = doc.payload?["url"] {
                try Self.validate(url, field: "payload.url", maximumBytes: Self.maximumURLBytes)
            }
            return .moduleRun(
                name: module,
                targetID: targetID,
                path: doc.path,
                payload: doc.payload ?? [:]
            )
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

    /// Decodes the exact internal action text displayed in the human review surface.
    public func decodeReviewedAction(from data: Data) throws -> CoreAction {
        let object = try Self.decodeJSONObject(from: data)
        try Self.validateReviewedActionFields(object)
        let action: CoreAction
        do {
            action = try JSONDecoder().decode(CoreAction.self, from: data)
        } catch {
            throw CoreError.schemaValidation("malformed reviewed action: \(error.localizedDescription)")
        }
        switch action {
        case .quicklinkUpsert(_, _, let url, _):
            try QuicklinkStore.validateURL(url)
        case .webConfigSet(_, let baseURL):
            try Self.validate(baseURL, field: "baseURL", maximumBytes: Self.maximumURLBytes)
        case .moduleRun(let module, let targetID, let path, let payload):
            try Self.validate(module, field: "module", maximumBytes: Self.maximumIdentifierBytes)
            try Self.validate(targetID, field: "targetID", maximumBytes: Self.maximumNameBytes)
            try Self.validateOptional(path, field: "path", maximumBytes: Self.maximumURLBytes)
            if case .string(let url) = payload["url"] {
                try Self.validate(url, field: "payload.url", maximumBytes: Self.maximumURLBytes)
            }
        case .agentCLI(let command):
            try Self.validate(command, field: "command", maximumBytes: Self.maximumIdentifierBytes)
        case .extensionInstall(let sourcePath):
            try Self.validate(sourcePath, field: "sourcePath", maximumBytes: Self.maximumURLBytes)
        case .extensionGrant(let extensionID, let entitlement, _):
            try Self.validate(extensionID, field: "extensionID", maximumBytes: Self.maximumIdentifierBytes)
            try Self.validate(entitlement, field: "entitlement", maximumBytes: Self.maximumIdentifierBytes)
        default:
            break
        }
        return action
    }

    public func reviewedText(for action: CoreAction) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(action)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.schemaValidation("reviewed action is not UTF-8")
        }
        return text
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
        case .moduleRun(let module, let targetID, let path, let payload):
            doc = ExternalActionDocument(
                action: "module.run",
                module: module,
                targetID: targetID,
                path: path,
                payload: payload
            )
        case .clipboardIgnoreAdd, .clipboardIgnoreRemove, .clipboardIngestRich:
            throw CoreError.schemaValidation("clipboard ignore actions are not external-wireable")
        default:
            throw CoreError.schemaValidation("action \(action.name) is not external-wireable")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(doc)
    }
}

extension SchemaGate {
    static func decodeJSONObject(
        from data: Data,
        allowedKeys: Set<String>? = nil
    ) throws -> [String: Any] {
        guard data.count <= maximumDocumentBytes else {
            throw CoreError.schemaValidation("JSON document exceeds byte limit")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CoreError.schemaValidation("malformed JSON: \(error.localizedDescription)")
        }
        guard let object = value as? [String: Any] else {
            throw CoreError.schemaValidation("JSON document must be an object")
        }
        var nodeCount = 0
        try validateJSONValue(object, depth: 0, nodeCount: &nodeCount)
        if let allowedKeys {
            try rejectUnknownFields(in: object, allowed: allowedKeys)
        }
        return object
    }

    static func rejectUnknownFields(in object: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw CoreError.schemaValidation("unknown field: \(unknown[0])")
        }
    }

    private static func validateActionFields(_ object: [String: Any]) throws {
        guard let action = object["action"] as? String else {
            throw CoreError.schemaValidation("action must be a string")
        }
        let fields: Set<String>
        switch action {
        case "settings.set": fields = ["v", "action", "key", "value"]
        case "settings.delete": fields = ["v", "action", "key"]
        case "snippet.upsert": fields = ["v", "action", "id", "key", "body", "keyword"]
        case "snippet.delete": fields = ["v", "action", "id"]
        case "quicklink.upsert": fields = ["v", "action", "id", "key", "url", "keyword"]
        case "quicklink.delete", "clipboard.delete": fields = ["v", "action", "id"]
        case "module.run": fields = ["v", "action", "module", "targetID", "path", "payload"]
        default: fields = ["v", "action"]
        }
        try rejectUnknownFields(in: object, allowed: fields)
    }

    private static func validateReviewedActionFields(_ object: [String: Any]) throws {
        guard let action = object["name"] as? String else {
            throw CoreError.schemaValidation("reviewed action name must be a string")
        }
        let fields: Set<String>
        switch action {
        case "settings.set": fields = ["name", "key", "value"]
        case "settings.delete": fields = ["name", "key"]
        case "snippet.upsert": fields = ["name", "id", "key", "body", "keyword"]
        case "snippet.delete": fields = ["name", "id"]
        case "clipboard.ingest":
            fields = ["name", "id", "text", "sourceApp", "createdAt", "pinned"]
        case "clipboard.ingestRich":
            fields = [
                "name", "id", "text", "sourceApp", "createdAt", "pinned",
                "contentKind", "flavor", "data",
            ]
        case "clipboard.delete": fields = ["name", "id"]
        case "clipboard.pin": fields = ["name", "id", "pinned"]
        case "clipboard.touch": fields = ["name", "id", "createdAt"]
        case "clipboard.clearUnpinned", "agent.version": fields = ["name"]
        case "clipboard.ignore.add", "clipboard.ignore.remove": fields = ["name", "entry"]
        case "quicklink.upsert": fields = ["name", "id", "key", "url", "keyword"]
        case "quicklink.delete": fields = ["name", "id"]
        case "alias.set":
            fields = ["name", "keyword", "targetResultID", "title", "kind", "path", "payload"]
        case "alias.delete": fields = ["name", "keyword"]
        case "favorite.add": fields = ["name", "id", "resultID", "title", "kind", "path"]
        case "favorite.remove": fields = ["name", "resultID"]
        case "import.reset": fields = ["name", "includeClipboard"]
        case "web.config.set": fields = ["name", "enabled", "baseURL"]
        case "fts.setEnabled": fields = ["name", "enabled"]
        case "proposal.decision": fields = ["name", "id", "state", "reason"]
        case "agent.search": fields = ["name", "query", "includedSensitive"]
        case "agent.cli": fields = ["name", "command"]
        case "extension.install": fields = ["name", "sourcePath"]
        case "extension.grant": fields = ["name", "extensionID", "entitlement", "granted"]
        case "module.run": fields = ["name", "module", "targetID", "path", "payload"]
        default: fields = ["name"]
        }
        try rejectUnknownFields(in: object, allowed: fields)
    }

    private static func validateJSONValue(
        _ value: Any,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= maximumNestingDepth else {
            throw CoreError.schemaValidation("JSON nesting exceeds depth limit")
        }
        nodeCount += 1
        guard nodeCount <= maximumJSONNodes else {
            throw CoreError.schemaValidation("JSON document exceeds node limit")
        }
        switch value {
        case let string as String:
            try validate(string, field: "string", maximumBytes: maximumStringBytes)
        case let array as [Any]:
            guard array.count <= maximumCollectionEntries else {
                throw CoreError.schemaValidation("JSON array exceeds entry limit")
            }
            for child in array {
                try validateJSONValue(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        case let object as [String: Any]:
            guard object.count <= maximumCollectionEntries else {
                throw CoreError.schemaValidation("JSON object exceeds entry limit")
            }
            for (key, child) in object {
                try validate(key, field: "object key", maximumBytes: maximumIdentifierBytes)
                try validateJSONValue(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        case let number as NSNumber:
            guard number.doubleValue.isFinite else {
                throw CoreError.schemaValidation("JSON number must be finite")
            }
        case is NSNull:
            return
        default:
            throw CoreError.schemaValidation("unsupported JSON value")
        }
    }

    private static func validate(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw CoreError.schemaValidation("\(field) exceeds byte limit")
        }
    }

    private static func validateOptional(
        _ value: String?,
        field: String,
        maximumBytes: Int
    ) throws {
        if let value { try validate(value, field: field, maximumBytes: maximumBytes) }
    }
}
