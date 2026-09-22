import Foundation

/// Loopback client for the local `verdict` typed-decision daemon
/// (`POST /v1/systemone` on `127.0.0.1`). Like `LocalModelClient`, this is a
/// declared network file: the only place the verdict call touches the network,
/// and every call is gated on a journaled `.localModel` egress authorization with
/// a loopback endpoint (on-machine, never off-device). The network-sovereignty
/// gate allowlists this file and checks the `permits` guard below.
public protocol VerdictHTTPTransport: Sendable {
    func systemOne(
        url: URL, token: String, body: Data, authorization: EgressAuthorization?
    ) async throws -> Data
}

public struct LiveVerdictHTTPTransport: VerdictHTTPTransport {
    public var session: URLSession
    public var timeout: TimeInterval
    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
    }

    public func systemOne(
        url: URL, token: String, body: Data, authorization: EgressAuthorization?
    ) async throws -> Data {
        guard authorization?.permits(url: url, purpose: .localModel) == true else {
            throw CoreError.store("verdict request lacks matching journaled egress authorization")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Summon (macOS launcher; on-device AI)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CoreError.store("verdict HTTP \(http.statusCode)")
        }
        return data
    }
}
