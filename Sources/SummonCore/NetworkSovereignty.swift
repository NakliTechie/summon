import Darwin
import Foundation

public enum EgressPurpose: String, Sendable, Codable, CaseIterable {
    case appcast
    case userWeb = "user.web"
    case userModelFetch = "user.ai.modelFetch"
    /// A user-run local model server (Ollama / LM Studio) on a loopback endpoint —
    /// on-machine, never off-device, but journaled like any other egress.
    case localModel = "user.ai.local"
}

public struct EgressAuthorization: Sendable, Equatable {
    public let purpose: EgressPurpose
    public let host: String
    public let actor: ActorTag
    public let journalEnvelopeID: UUID

    fileprivate init(
        purpose: EgressPurpose,
        host: String,
        actor: ActorTag,
        journalEnvelopeID: UUID
    ) {
        self.purpose = purpose
        self.host = host
        self.actor = actor
        self.journalEnvelopeID = journalEnvelopeID
    }

    public func permits(url: URL, purpose: EgressPurpose) -> Bool {
        self.purpose == purpose && url.host?.lowercased() == host
    }
}

public enum NetworkSovereignty {
    private static let auditLock = NSLock()

    public static func authorize(
        url: URL,
        purpose: EgressPurpose,
        actor: ActorTag,
        journalEntry: JournalEntry,
        auditLogURL: URL? = nil
    ) throws -> EgressAuthorization {
        guard journalEntry.outcome == "applied" else {
            throw CoreError.store("egress requires an applied journal intent")
        }
        guard let scheme = url.scheme?.lowercased(), let rawHost = url.host, !rawHost.isEmpty else {
            throw CoreError.store("egress requires an absolute URL with a host")
        }
        let host = rawHost.lowercased()
        guard journalEntry.actor == actor,
              journalEntry.action == .egressRequested(purpose: purpose.rawValue, host: host) else {
            throw CoreError.store("egress request does not match the applied journal intent")
        }
        switch purpose {
        case .appcast:
            guard actor == .system, scheme == "https" else {
                throw CoreError.store("appcast egress requires system actor over HTTPS")
            }
        case .userWeb:
            guard actor == .user else {
                throw CoreError.store("web egress requires the interactive user actor")
            }
            let loopbackHTTP = scheme == "http" && WebSearchConfig.isLoopbackHost(host)
            guard scheme == "https" || loopbackHTTP else {
                throw CoreError.store("web egress requires HTTPS or a loopback HTTP endpoint")
            }
        case .userModelFetch:
            guard actor == .user, scheme == "https" else {
                throw CoreError.store("model-fetch egress requires the interactive user actor over HTTPS")
            }
        case .localModel:
            guard actor == .user else {
                throw CoreError.store("local-model egress requires the interactive user actor")
            }
            guard scheme == "http", WebSearchConfig.isLoopbackHost(host) else {
                throw CoreError.store("local-model egress requires a loopback HTTP endpoint")
            }
        }

        let authorization = EgressAuthorization(
            purpose: purpose,
            host: host,
            actor: actor,
            journalEnvelopeID: journalEntry.id
        )
        try appendAuditRecord(authorization, auditLogURL: auditLogURL)
        return authorization
    }

    private static func appendAuditRecord(
        _ authorization: EgressAuthorization,
        auditLogURL: URL?
    ) throws {
        let resolvedURL = auditLogURL ?? ProcessInfo.processInfo.environment["SUMMON_EGRESS_AUDIT_LOG"]
            .map { URL(fileURLWithPath: $0) }
        guard let resolvedURL else { return }

        let record: [String: String] = [
            "actor": authorization.actor.journalLabel,
            "host": authorization.host,
            "journalEnvelopeID": authorization.journalEnvelopeID.uuidString,
            "purpose": authorization.purpose.rawValue,
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)

        auditLock.lock()
        defer { auditLock.unlock() }
        let descriptor = Darwin.open(resolvedURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
            throw CoreError.io("egress audit log open failed")
        }
        defer { Darwin.close(descriptor) }
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == data.count else {
            throw CoreError.io("egress audit log write failed")
        }
    }
}
