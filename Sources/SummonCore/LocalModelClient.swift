import Foundation

/// Loopback client for a user-run OpenAI-compatible model server (Ollama on
/// :11434, LM Studio on :1234). The only file besides `WebSearch` permitted to
/// touch the network — every call is gated on a journaled `.localModel` egress
/// authorization, and the endpoint must be loopback (on-machine, never off-device).
public protocol LocalModelTransport: Sendable {
    /// Model ids the server offers (empty ⇒ nothing to use).
    func models(baseURL: URL, authorization: EgressAuthorization?) async throws -> [String]
    /// A single-shot chat completion for `prompt` against `model`.
    func chat(
        baseURL: URL, model: String, prompt: String, authorization: EgressAuthorization?
    ) async throws -> String
}

public struct LiveLocalModelTransport: LocalModelTransport {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func models(baseURL: URL, authorization: EgressAuthorization?) async throws -> [String] {
        let url = baseURL.appendingPathComponent("models")
        guard authorization?.permits(url: url, purpose: .localModel) == true else {
            throw CoreError.store("local-model request lacks matching journaled egress authorization")
        }
        let (data, response) = try await session.data(for: request(url))
        try Self.check(response)
        return (try? JSONDecoder().decode(ModelsList.self, from: data))?.data.map(\.id) ?? []
    }

    public func chat(
        baseURL: URL, model: String, prompt: String, authorization: EgressAuthorization?
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("chat/completions")
        guard authorization?.permits(url: url, purpose: .localModel) == true else {
            throw CoreError.store("local-model request lacks matching journaled egress authorization")
        }
        var req = request(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, messages: [ChatMessage(role: "user", content: prompt)], stream: false)
        )
        let (data, response) = try await session.data(for: req)
        try Self.check(response)
        guard let text = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content else {
            throw CoreError.store("local-model response had no content")
        }
        return text
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Summon (macOS launcher; on-device AI)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CoreError.store("local-model HTTP \(http.statusCode)")
        }
    }

    // OpenAI-compatible request/response shapes (Ollama + LM Studio both speak these).
    private struct ModelsList: Decodable { let data: [Model]; struct Model: Decodable { let id: String } }
    private struct ChatMessage: Codable { let role: String; let content: String }
    private struct ChatRequest: Encodable { let model: String; let messages: [ChatMessage]; let stream: Bool }
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: ChatMessage }
    }
}
