import XCTest
@testable import SummonAI
@testable import SummonCore

private struct FakeHTTP: VerdictHTTPTransport {
    let onCall: @Sendable (EgressAuthorization?) -> Void
    func systemOne(url: URL, token: String, body: Data, authorization: EgressAuthorization?) async throws -> Data {
        onCall(authorization)
        return Data(#"{"answers":{},"failures":{}}"#.utf8)
    }
}

final class CoreAuthorizedVerdictTransportTests: XCTestCase {
    /// The authorized transport journals + audits a `.localModel` egress and hands
    /// a matching authorization to the declared HTTP client. The client's own
    /// `permits` guard then holds — proving the egress gate fires before any POST.
    func testAuthorizesAndAuditsEgressAndPassesAMatchingAuthorization() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-egress-\(UUID().uuidString).log")
        setenv("SUMMON_EGRESS_AUDIT_LOG", auditURL.path, 1)
        let tokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-token-\(UUID().uuidString)")
        try "test-token".write(to: tokenURL, atomically: true, encoding: .utf8)
        defer {
            unsetenv("SUMMON_EGRESS_AUDIT_LOG")
            try? FileManager.default.removeItem(at: auditURL)
            try? FileManager.default.removeItem(at: tokenURL)
        }

        let endpoint = URL(string: "http://127.0.0.1:7311/v1/systemone")!
        var seenAuthorization: EgressAuthorization?
        let transport = CoreAuthorizedVerdictTransport(
            core: core,
            endpoint: endpoint,
            tokenURL: tokenURL,
            http: FakeHTTP { seenAuthorization = $0 }
        )
        _ = try await transport.systemOne(body: Data("{}".utf8))

        // The declared client received an authorization that permits this exact call.
        XCTAssertEqual(seenAuthorization?.permits(url: endpoint, purpose: .localModel), true)
        let audit = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(audit.contains("\"purpose\":\"user.ai.local\""), "egress was not audited as a local-model call")
        XCTAssertTrue(audit.contains("\"host\":\"127.0.0.1\""), "egress host was not audited")
    }
}
