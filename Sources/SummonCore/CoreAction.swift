import Foundation

/// Typed actions that enter the single action bus (invariant 7).
public enum CoreAction: Sendable, Hashable, Codable, Equatable {
    case settingsSet(key: String, value: JSONValue)
    case settingsDelete(key: String)
    case snippetUpsert(id: String, name: String, body: String, keyword: String?)
    case snippetDelete(id: String)
    case clipboardIngest(id: String, text: String, sourceApp: String?, createdAt: Date, pinned: Bool)
    case clipboardIngestRich(
        id: String,
        text: String,
        sourceApp: String?,
        createdAt: Date,
        pinned: Bool,
        contentKind: ClipboardContentKind,
        flavor: String,
        data: Data
    )
    case clipboardDelete(id: String)
    case clipboardPin(id: String, pinned: Bool)
    case clipboardTouch(id: String, createdAt: Date)
    case clipboardClearUnpinned
    case clipboardIgnoreAdd(entry: String)
    case clipboardIgnoreRemove(entry: String)
    case quicklinkUpsert(id: String, name: String, url: String, keyword: String?)
    case quicklinkDelete(id: String)
    case aliasSet(
        keyword: String,
        targetResultID: String,
        title: String,
        kind: String,
        path: String?,
        payload: [String: JSONValue]?
    )
    case aliasDelete(keyword: String)
    case favoriteAdd(id: String, resultID: String, title: String, kind: String, path: String?)
    case favoriteRemove(resultID: String)
    /// Replayable prelude for an atomic replace import.
    case importReset(includeClipboard: Bool)
    case webConfigSet(enabled: Bool, baseURL: String)
    /// External authorization effect. Journaled with intent/outcome and never replayed.
    case ftsConsentGrant
    case ftsSetEnabled(enabled: Bool)
    /// One atomic, actor-tagged launcher usage record.
    case usageRecord(
        resultID: String,
        title: String,
        kind: String,
        path: String?,
        payload: [String: JSONValue],
        query: String,
        historyID: String,
        usedAt: Date
    )
    case frecencyRestore(entry: FrecencyEntry)
    case historyRestore(entry: SearchHistoryEntry)
    case stagedRestore(proposal: PersistedStagedProposal)
    /// Audit record for exact-model consent stored by the optional AI product.
    case modelConsentGrant(modelID: String)
    case proposalDecision(id: String, state: String, reason: String?)
    /// Audit-only agent read events. These never mutate stores during replay.
    case agentSearch(query: String, includedSensitive: Bool)
    case agentVersion
    case agentCLI(command: String)
    /// Applied journal intent required before an approved network path opens.
    case egressRequested(purpose: String, host: String)
    /// User-authorized extension authority changes. The executor owns the filesystem effect.
    case extensionInstall(sourcePath: String)
    case extensionGrant(extensionID: String, entitlement: String, granted: Bool)
    /// Side-effecting module invoke (open/reveal/copy). Journaled; applied via ModuleExecuting.
    case moduleRun(name: String, targetID: String, path: String?, payload: [String: JSONValue])

    public var name: String {
        switch self {
        case .settingsSet: return "settings.set"
        case .settingsDelete: return "settings.delete"
        case .snippetUpsert: return "snippet.upsert"
        case .snippetDelete: return "snippet.delete"
        case .clipboardIngest: return "clipboard.ingest"
        case .clipboardIngestRich: return "clipboard.ingestRich"
        case .clipboardDelete: return "clipboard.delete"
        case .clipboardPin: return "clipboard.pin"
        case .clipboardTouch: return "clipboard.touch"
        case .clipboardClearUnpinned: return "clipboard.clearUnpinned"
        case .clipboardIgnoreAdd: return "clipboard.ignore.add"
        case .clipboardIgnoreRemove: return "clipboard.ignore.remove"
        case .quicklinkUpsert: return "quicklink.upsert"
        case .quicklinkDelete: return "quicklink.delete"
        case .aliasSet: return "alias.set"
        case .aliasDelete: return "alias.delete"
        case .favoriteAdd: return "favorite.add"
        case .favoriteRemove: return "favorite.remove"
        case .importReset: return "import.reset"
        case .webConfigSet: return "web.config.set"
        case .ftsConsentGrant: return "fts.consent.grant"
        case .ftsSetEnabled: return "fts.setEnabled"
        case .usageRecord: return "usage.record"
        case .frecencyRestore: return "frecency.restore"
        case .historyRestore: return "history.restore"
        case .stagedRestore: return "staged.restore"
        case .modelConsentGrant: return "model.consent.grant"
        case .proposalDecision: return "proposal.decision"
        case .agentSearch: return "agent.search"
        case .agentVersion: return "agent.version"
        case .agentCLI: return "agent.cli"
        case .egressRequested: return "egress.requested"
        case .extensionInstall: return "extension.install"
        case .extensionGrant: return "extension.grant"
        case .moduleRun: return "module.run"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, key, value, id, body, keyword, text, sourceApp, createdAt, pinned, url, entry
        case targetID, path, payload, module, contentKind, flavor, data
        case enabled, baseURL, query, includedSensitive, state, reason, purpose, host
        case targetResultID, title, kind, resultID, includeClipboard
        case command, sourcePath, extensionID, entitlement, granted
        case historyID, usedAt, modelID, record, proposal
    }

    // Codable exhaustiveness keeps every journal name in one decoder switch.
    // swiftlint:disable:next function_body_length
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
            guard let timestamp = try c.decodeIfPresent(String.self, forKey: .createdAt),
                  let createdAt = Self.timestampFormatter.date(from: timestamp)
                    ?? ISO8601DateFormatter().date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .createdAt,
                    in: c,
                    debugDescription: "clipboard.ingest requires a valid timestamp"
                )
            }
            self = .clipboardIngest(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                sourceApp: try c.decodeIfPresent(String.self, forKey: .sourceApp),
                createdAt: createdAt,
                pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            )
        case "clipboard.ingestRich":
            guard let timestamp = try c.decodeIfPresent(String.self, forKey: .createdAt),
                  let createdAt = Self.timestampFormatter.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .createdAt,
                    in: c,
                    debugDescription: "clipboard.ingestRich requires a valid timestamp"
                )
            }
            self = .clipboardIngestRich(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                sourceApp: try c.decodeIfPresent(String.self, forKey: .sourceApp),
                createdAt: createdAt,
                pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
                contentKind: try c.decode(ClipboardContentKind.self, forKey: .contentKind),
                flavor: try c.decode(String.self, forKey: .flavor),
                data: try c.decode(Data.self, forKey: .data)
            )
        case "clipboard.delete":
            self = .clipboardDelete(id: try c.decode(String.self, forKey: .id))
        case "clipboard.pin":
            self = .clipboardPin(
                id: try c.decode(String.self, forKey: .id),
                pinned: try c.decode(Bool.self, forKey: .pinned)
            )
        case "clipboard.touch":
            guard let timestamp = try c.decodeIfPresent(String.self, forKey: .createdAt),
                  let createdAt = Self.timestampFormatter.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .createdAt,
                    in: c,
                    debugDescription: "clipboard.touch requires a valid timestamp"
                )
            }
            self = .clipboardTouch(
                id: try c.decode(String.self, forKey: .id),
                createdAt: createdAt
            )
        case "clipboard.clearUnpinned":
            self = .clipboardClearUnpinned
        case "clipboard.ignore.add":
            self = .clipboardIgnoreAdd(entry: try c.decode(String.self, forKey: .entry))
        case "clipboard.ignore.remove":
            self = .clipboardIgnoreRemove(entry: try c.decode(String.self, forKey: .entry))
        case "quicklink.upsert":
            self = .quicklinkUpsert(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .key),
                url: try c.decode(String.self, forKey: .url),
                keyword: try c.decodeIfPresent(String.self, forKey: .keyword)
            )
        case "quicklink.delete":
            self = .quicklinkDelete(id: try c.decode(String.self, forKey: .id))
        case "alias.set", "alias.delete", "favorite.add", "favorite.remove", "import.reset":
            self = try Self.decodeImportAction(named: name, from: c)
        case "web.config.set":
            self = .webConfigSet(
                enabled: try c.decode(Bool.self, forKey: .enabled),
                baseURL: try c.decode(String.self, forKey: .baseURL)
            )
        case "fts.consent.grant":
            self = .ftsConsentGrant
        case "fts.setEnabled":
            self = .ftsSetEnabled(enabled: try c.decode(Bool.self, forKey: .enabled))
        case "usage.record":
            guard let timestamp = try c.decodeIfPresent(String.self, forKey: .usedAt),
                  let usedAt = Self.timestampFormatter.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .usedAt,
                    in: c,
                    debugDescription: "usage.record requires a valid timestamp"
                )
            }
            self = .usageRecord(
                resultID: try c.decode(String.self, forKey: .resultID),
                title: try c.decode(String.self, forKey: .title),
                kind: try c.decode(String.self, forKey: .kind),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                payload: try c.decodeIfPresent(
                    [String: JSONValue].self,
                    forKey: .payload
                ) ?? [:],
                query: try c.decode(String.self, forKey: .query),
                historyID: try c.decode(String.self, forKey: .historyID),
                usedAt: usedAt
            )
        case "frecency.restore":
            self = .frecencyRestore(entry: try c.decode(FrecencyEntry.self, forKey: .record))
        case "history.restore":
            self = .historyRestore(entry: try c.decode(SearchHistoryEntry.self, forKey: .record))
        case "staged.restore":
            self = .stagedRestore(
                proposal: try c.decode(PersistedStagedProposal.self, forKey: .proposal)
            )
        case "model.consent.grant":
            self = .modelConsentGrant(modelID: try c.decode(String.self, forKey: .modelID))
        case "proposal.decision":
            self = .proposalDecision(
                id: try c.decode(String.self, forKey: .id),
                state: try c.decode(String.self, forKey: .state),
                reason: try c.decodeIfPresent(String.self, forKey: .reason)
            )
        default:
            self = try Self.decodeAuxiliaryAction(named: name, from: c)
        }
    }

    private static func decodeImportAction(
        named name: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> CoreAction {
        switch name {
        case "alias.set":
            return .aliasSet(
                keyword: try container.decode(String.self, forKey: .keyword),
                targetResultID: try container.decode(String.self, forKey: .targetResultID),
                title: try container.decode(String.self, forKey: .title),
                kind: try container.decode(String.self, forKey: .kind),
                path: try container.decodeIfPresent(String.self, forKey: .path),
                payload: try container.decodeIfPresent(
                    [String: JSONValue].self,
                    forKey: .payload
                )
            )
        case "alias.delete":
            return .aliasDelete(keyword: try container.decode(String.self, forKey: .keyword))
        case "favorite.add":
            return .favoriteAdd(
                id: try container.decode(String.self, forKey: .id),
                resultID: try container.decode(String.self, forKey: .resultID),
                title: try container.decode(String.self, forKey: .title),
                kind: try container.decode(String.self, forKey: .kind),
                path: try container.decodeIfPresent(String.self, forKey: .path)
            )
        case "favorite.remove":
            return .favoriteRemove(
                resultID: try container.decode(String.self, forKey: .resultID)
            )
        case "import.reset":
            return .importReset(
                includeClipboard: try container.decode(Bool.self, forKey: .includeClipboard)
            )
        default:
            throw CoreError.unknownAction(name)
        }
    }

    private static func decodeAuxiliaryAction(
        named name: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> CoreAction {
        switch name {
        case "agent.search":
            return .agentSearch(
                query: try container.decode(String.self, forKey: .query),
                includedSensitive: try container.decode(Bool.self, forKey: .includedSensitive)
            )
        case "agent.version":
            return .agentVersion
        case "agent.cli":
            return .agentCLI(command: try container.decode(String.self, forKey: .command))
        case "egress.requested":
            return .egressRequested(
                purpose: try container.decode(String.self, forKey: .purpose),
                host: try container.decode(String.self, forKey: .host)
            )
        case "extension.install":
            return .extensionInstall(
                sourcePath: try container.decode(String.self, forKey: .sourcePath)
            )
        case "extension.grant":
            return .extensionGrant(
                extensionID: try container.decode(String.self, forKey: .extensionID),
                entitlement: try container.decode(String.self, forKey: .entitlement),
                granted: try container.decode(Bool.self, forKey: .granted)
            )
        case "module.run":
            return .moduleRun(
                name: try container.decode(String.self, forKey: .module),
                targetID: try container.decode(String.self, forKey: .targetID),
                path: try container.decodeIfPresent(String.self, forKey: .path),
                payload: try container.decodeIfPresent(
                    [String: JSONValue].self,
                    forKey: .payload
                ) ?? [:]
            )
        default:
            throw CoreError.unknownAction(name)
        }
    }

    // Codable exhaustiveness keeps every journal case in one payload switch.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        case .clipboardIngestRich(
            let id,
            let text,
            let sourceApp,
            let createdAt,
            let pinned,
            let contentKind,
            let flavor,
            let data
        ):
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
            try c.encode(Self.timestampFormatter.string(from: createdAt), forKey: .createdAt)
            try c.encode(pinned, forKey: .pinned)
            try c.encode(contentKind, forKey: .contentKind)
            try c.encode(flavor, forKey: .flavor)
            try c.encode(data, forKey: .data)
        case .clipboardDelete(let id):
            try c.encode(id, forKey: .id)
        case .clipboardPin(let id, let pinned):
            try c.encode(id, forKey: .id)
            try c.encode(pinned, forKey: .pinned)
        case .clipboardTouch(let id, let createdAt):
            try c.encode(id, forKey: .id)
            try c.encode(Self.timestampFormatter.string(from: createdAt), forKey: .createdAt)
        case .clipboardClearUnpinned:
            break
        case .clipboardIgnoreAdd(let entry), .clipboardIgnoreRemove(let entry):
            try c.encode(entry, forKey: .entry)
        case .quicklinkUpsert(let id, let name, let url, let keyword):
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .key)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(keyword, forKey: .keyword)
        case .quicklinkDelete(let id):
            try c.encode(id, forKey: .id)
        case .aliasSet(let keyword, let targetResultID, let title, let kind, let path, let payload):
            try c.encode(keyword, forKey: .keyword)
            try c.encode(targetResultID, forKey: .targetResultID)
            try c.encode(title, forKey: .title)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(payload, forKey: .payload)
        case .aliasDelete(let keyword):
            try c.encode(keyword, forKey: .keyword)
        case .favoriteAdd(let id, let resultID, let title, let kind, let path):
            try c.encode(id, forKey: .id)
            try c.encode(resultID, forKey: .resultID)
            try c.encode(title, forKey: .title)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(path, forKey: .path)
        case .favoriteRemove(let resultID):
            try c.encode(resultID, forKey: .resultID)
        case .importReset(let includeClipboard):
            try c.encode(includeClipboard, forKey: .includeClipboard)
        case .webConfigSet(let enabled, let baseURL):
            try c.encode(enabled, forKey: .enabled)
            try c.encode(baseURL, forKey: .baseURL)
        case .ftsConsentGrant:
            break
        case .ftsSetEnabled(let enabled):
            try c.encode(enabled, forKey: .enabled)
        case .usageRecord(
            let resultID,
            let title,
            let kind,
            let path,
            let payload,
            let query,
            let historyID,
            let usedAt
        ):
            try c.encode(resultID, forKey: .resultID)
            try c.encode(title, forKey: .title)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(payload, forKey: .payload)
            try c.encode(query, forKey: .query)
            try c.encode(historyID, forKey: .historyID)
            try c.encode(Self.timestampFormatter.string(from: usedAt), forKey: .usedAt)
        case .frecencyRestore(let entry):
            try c.encode(entry, forKey: .record)
        case .historyRestore(let entry):
            try c.encode(entry, forKey: .record)
        case .stagedRestore(let proposal):
            try c.encode(proposal, forKey: .proposal)
        case .modelConsentGrant(let modelID):
            try c.encode(modelID, forKey: .modelID)
        case .proposalDecision(let id, let state, let reason):
            try c.encode(id, forKey: .id)
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .agentSearch(let query, let includedSensitive):
            try c.encode(query, forKey: .query)
            try c.encode(includedSensitive, forKey: .includedSensitive)
        case .agentVersion:
            break
        case .agentCLI(let command):
            try c.encode(command, forKey: .command)
        case .egressRequested(let purpose, let host):
            try c.encode(purpose, forKey: .purpose)
            try c.encode(host, forKey: .host)
        case .extensionInstall(let sourcePath):
            try c.encode(sourcePath, forKey: .sourcePath)
        case .extensionGrant(let extensionID, let entitlement, let granted):
            try c.encode(extensionID, forKey: .extensionID)
            try c.encode(entitlement, forKey: .entitlement)
            try c.encode(granted, forKey: .granted)
        case .moduleRun(let module, let targetID, let path, let payload):
            try c.encode(module, forKey: .module)
            try c.encode(targetID, forKey: .targetID)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(payload, forKey: .payload)
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
