import Foundation

/// W1 opt-in web meta-search (SearXNG). Default OFF. User-owned endpoint only.
public struct WebSearchConfig: Sendable, Hashable, Codable, Equatable {
    public var enabled: Bool
    /// Empty until user sets; after opt-in UI may preset localhost.
    public var baseURL: String
    /// When false (default), only loopback hosts are allowed.
    public var allowNonLoopback: Bool
    public static let localhostPreset = "http://127.0.0.1:8080"

    public static let `default` = WebSearchConfig(enabled: false, baseURL: "", allowNonLoopback: false)

    public init(enabled: Bool = false, baseURL: String = "", allowNonLoopback: Bool = false) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.allowNonLoopback = allowNonLoopback
    }

    /// Apply Chirag 2026-08-04 default: after enabling, preset localhost if URL empty.
    public mutating func enableWithLocalhostPreset() {
        enabled = true
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseURL = Self.localhostPreset
        }
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    public static func isAllowedHost(_ url: URL, allowNonLoopback: Bool) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        if isLoopbackHost(host) { return true }
        return allowNonLoopback
    }
}

public struct WebHit: Sendable, Hashable, Codable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public protocol WebSearchProviding: Sendable {
    func search(query: String, limit: Int) async throws -> [WebHit]
}

public enum WebSearchError: Error, Equatable, LocalizedError {
    case disabled
    case invalidBaseURL
    case network(String)
    case decode

    public var errorDescription: String? {
        switch self {
        case .disabled: return "web search is off (opt-in)"
        case .invalidBaseURL: return "invalid SearXNG base URL"
        case .network(let s): return s
        case .decode: return "SearXNG response decode failed"
        }
    }
}

/// SearXNG JSON API client (`/search?q=&format=json`).
public struct SearXNGClient: WebSearchProviding, Sendable {
    public let config: WebSearchConfig
    public var session: URLSession

    public init(config: WebSearchConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(query: String, limit: Int = 8) async throws -> [WebHit] {
        guard config.enabled else { throw WebSearchError.disabled }
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = URL(string: base), let scheme = root.scheme,
              scheme == "http" || scheme == "https" else {
            throw WebSearchError.invalidBaseURL
        }
        // Loopback-only by default (SSRF mitigation). Set web.search.allowNonLoopback for advanced.
        guard WebSearchConfig.isAllowedHost(root, allowNonLoopback: config.allowNonLoopback) else {
            throw WebSearchError.invalidBaseURL
        }
        var components = URLComponents(
            url: root.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw WebSearchError.invalidBaseURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw WebSearchError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebSearchError.network("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            throw WebSearchError.decode
        }
        return results.prefix(limit).compactMap { row in
            guard let title = row["title"] as? String,
                  let link = row["url"] as? String else { return nil }
            let snippet = (row["content"] as? String) ?? ""
            return WebHit(title: title, url: link, snippet: snippet)
        }
    }
}

/// Test double — no network.
public struct FakeWebSearchProvider: WebSearchProviding, Sendable {
    public var hits: [WebHit]

    public init(hits: [WebHit] = [
        WebHit(title: "Example", url: "https://example.com", snippet: "Example domain"),
    ]) {
        self.hits = hits
    }

    public func search(query: String, limit: Int) async throws -> [WebHit] {
        _ = query
        return Array(hits.prefix(limit))
    }
}

public enum WebEnrich {
    /// Build a prompt for L1/L0 from hits + question.
    public static func enrichPrompt(question: String, hits: [WebHit]) -> String {
        var lines = [
            "Answer the question using only the sources below. Cite titles. Be concise.",
            "Question: \(question)",
            "Sources:",
        ]
        for (i, h) in hits.enumerated() {
            lines.append("\(i + 1). \(h.title) — \(h.url)\n   \(h.snippet.prefix(200))")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatHitsOnly(_ hits: [WebHit]) -> String {
        hits.enumerated().map { i, h in
            "\(i + 1). \(h.title)\n   \(h.url)\n   \(h.snippet.prefix(160))"
        }.joined(separator: "\n")
    }
}
