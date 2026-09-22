import Foundation
import SummonCore

/// The shipping transport for the verdict loopback call. It journals + audits a
/// `.localModel` egress through the core action bus, then hands the authorization
/// to `VerdictHTTPTransport` (SummonCore's declared network file), which enforces
/// the same `permits` check before the POST. There is no raw network primitive in
/// SummonAI — the call goes through the allowlisted client, exactly like
/// `LocalModelRung` → `LocalModelClient`.
public struct CoreAuthorizedVerdictTransport: VerdictTransport {
    private let core: SummonCore
    private let endpoint: URL
    private let tokenURL: URL
    private let http: any VerdictHTTPTransport

    public init(
        core: SummonCore,
        endpoint: URL = URL(string: "http://127.0.0.1:7311/v1/systemone")!,
        tokenURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/verdict/token"),
        http: any VerdictHTTPTransport = LiveVerdictHTTPTransport()
    ) {
        self.core = core
        self.endpoint = endpoint
        self.tokenURL = tokenURL
        self.http = http
    }

    public func systemOne(body: Data) async throws -> Data {
        // Journaled gate first, so egress is recorded even if the token read or
        // the POST then fails.
        let authorization = try authorize(endpoint)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await http.systemOne(
            url: endpoint, token: token, body: body, authorization: authorization
        )
    }

    private func authorize(_ url: URL) throws -> EgressAuthorization {
        let host = url.host ?? "127.0.0.1"
        let intent = try core.dispatch(
            action: .egressRequested(purpose: EgressPurpose.localModel.rawValue, host: host),
            actor: .user
        )
        guard let entry = try core.journal.entry(id: intent.envelopeID) else {
            throw ModelRungError.generationFailed("verdict egress intent missing after dispatch")
        }
        return try NetworkSovereignty.authorize(
            url: url, purpose: .localModel, actor: .user, journalEntry: entry
        )
    }
}
