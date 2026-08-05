import Foundation
import XCTest
@testable import SummonCore

final class NetworkSovereigntyTests: XCTestCase {
    func testJournaledUserWebIntentProducesBoundAuthorizationAndAuditRecord() throws {
        let core = try SummonCore.inMemory()
        let url = try XCTUnwrap(URL(string: "https://search.example.test/root"))
        let result = try core.dispatch(
            action: .egressRequested(purpose: EgressPurpose.userWeb.rawValue, host: "search.example.test"),
            actor: .user
        )
        let entry = try XCTUnwrap(core.journal.entry(id: result.envelopeID))
        let auditURL = temporaryAuditURL()
        defer { try? FileManager.default.removeItem(at: auditURL) }

        let authorization = try NetworkSovereignty.authorize(
            url: url,
            purpose: .userWeb,
            actor: .user,
            journalEntry: entry,
            auditLogURL: auditURL
        )

        XCTAssertTrue(authorization.permits(
            url: URL(string: "https://search.example.test/search?q=summon")!,
            purpose: .userWeb
        ))
        XCTAssertFalse(authorization.permits(url: url, purpose: .appcast))
        XCTAssertEqual(authorization.journalEnvelopeID, result.envelopeID)

        let records = try auditRecords(at: auditURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["actor"] as? String, "user")
        XCTAssertEqual(records[0]["host"] as? String, "search.example.test")
        XCTAssertEqual(records[0]["purpose"] as? String, EgressPurpose.userWeb.rawValue)
        XCTAssertEqual(records[0]["journalEnvelopeID"] as? String, result.envelopeID.uuidString)
    }

    func testAuthorizationRejectsActorPurposeHostAndOutcomeMismatches() throws {
        let core = try SummonCore.inMemory()
        let url = URL(string: "https://search.example.test")!
        let result = try core.dispatch(
            action: .egressRequested(purpose: EgressPurpose.userWeb.rawValue, host: "search.example.test"),
            actor: .user
        )
        let entry = try XCTUnwrap(core.journal.entry(id: result.envelopeID))

        XCTAssertThrowsError(try NetworkSovereignty.authorize(
            url: url,
            purpose: .userWeb,
            actor: .system,
            journalEntry: entry
        ))
        XCTAssertThrowsError(try NetworkSovereignty.authorize(
            url: URL(string: "https://other.example.test")!,
            purpose: .userWeb,
            actor: .user,
            journalEntry: entry
        ))
        XCTAssertThrowsError(try NetworkSovereignty.authorize(
            url: URL(string: "https://huggingface.co/example/model")!,
            purpose: .userModelFetch,
            actor: .user,
            journalEntry: entry
        ))

        let rejected = JournalEntry(
            seq: entry.seq,
            id: entry.id,
            actor: entry.actor,
            timestamp: entry.timestamp,
            action: entry.action,
            outcome: "rejected:test"
        )
        XCTAssertThrowsError(try NetworkSovereignty.authorize(
            url: url,
            purpose: .userWeb,
            actor: .user,
            journalEntry: rejected
        ))
    }

    func testTransportPolicyAllowsOnlyDeclaredActorAndSchemePairs() throws {
        let webEntry = try journalEntry(
            actor: .user,
            purpose: .userWeb,
            host: "127.0.0.1"
        )
        XCTAssertNoThrow(try NetworkSovereignty.authorize(
            url: URL(string: "http://127.0.0.1:8080")!,
            purpose: .userWeb,
            actor: .user,
            journalEntry: webEntry
        ))

        let remoteHTTPEntry = try journalEntry(
            actor: .user,
            purpose: .userWeb,
            host: "search.example.test"
        )
        XCTAssertThrowsError(try NetworkSovereignty.authorize(
            url: URL(string: "http://search.example.test")!,
            purpose: .userWeb,
            actor: .user,
            journalEntry: remoteHTTPEntry
        ))

        let appcastEntry = try journalEntry(
            actor: .system,
            purpose: .appcast,
            host: "updates.example.test"
        )
        XCTAssertNoThrow(try NetworkSovereignty.authorize(
            url: URL(string: "https://updates.example.test/appcast.xml")!,
            purpose: .appcast,
            actor: .system,
            journalEntry: appcastEntry
        ))
    }

    func testSearXNGRefusesToOpenSessionWithoutBoundAuthorization() async {
        let config = WebSearchConfig(
            enabled: true,
            baseURL: "http://127.0.0.1:9",
            allowNonLoopback: false
        )
        do {
            _ = try await SearXNGClient(config: config).search(query: "summon")
            XCTFail("expected authorization refusal")
        } catch let error as WebSearchError {
            XCTAssertEqual(
                error,
                .network("web request lacks matching journaled egress authorization")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEgressActionJSONRoundTrip() throws {
        let action = CoreAction.egressRequested(purpose: "user.web", host: "search.example.test")
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(CoreAction.self, from: data), action)
    }

    private func journalEntry(
        actor: ActorTag,
        purpose: EgressPurpose,
        host: String
    ) throws -> JournalEntry {
        let core = try SummonCore.inMemory()
        let result = try core.dispatch(
            action: .egressRequested(purpose: purpose.rawValue, host: host),
            actor: actor
        )
        return try XCTUnwrap(core.journal.entry(id: result.envelopeID))
    }

    private func temporaryAuditURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-egress-audit-\(UUID().uuidString).jsonl")
    }

    private func auditRecords(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
}
