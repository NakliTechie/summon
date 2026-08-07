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

/// A provider `searchAndAnswer` can drive: it exposes its egress host and takes
/// the journaled `.userWeb` authorization the sovereignty gate requires.
public protocol AuthorizedWebSearchProvider: Sendable {
    var host: String { get }
    func search(query: String, limit: Int, authorization: EgressAuthorization?) async throws -> [WebHit]
}

/// SearXNG JSON API client (`/search?q=&format=json`).
public struct SearXNGClient: AuthorizedWebSearchProvider, Sendable {
    public let config: WebSearchConfig
    public var session: URLSession

    public var host: String {
        URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
    }

    public init(config: WebSearchConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(
        query: String,
        limit: Int = 8,
        authorization: EgressAuthorization? = nil
    ) async throws -> [WebHit] {
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
        guard authorization?.permits(url: url, purpose: .userWeb) == true else {
            throw WebSearchError.network("web request lacks matching journaled egress authorization")
        }

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

/// Keyless zero-setup search floor (the "pick your poison" default rung):
/// Wikipedia's REST search API. No key, no Docker, no CAPTCHA — but encyclopedic
/// only, no live/current web. HTTPS + journaled `.userWeb` egress, same gate as
/// SearXNG. Current-web tiers (SearXNG self-host, BYO-key) are the upgrades.
public struct WikipediaSearchClient: AuthorizedWebSearchProvider, Sendable {
    public let host: String
    public var session: URLSession

    public init(host: String = "en.wikipedia.org", session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    public func search(
        query: String,
        limit: Int = 5,
        authorization: EgressAuthorization? = nil
    ) async throws -> [WebHit] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/rest.php/v1/search/page"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 10)))),
        ]
        guard let url = components.url else { throw WebSearchError.invalidBaseURL }
        guard authorization?.permits(url: url, purpose: .userWeb) == true else {
            throw WebSearchError.network("web request lacks matching journaled egress authorization")
        }
        var request = URLRequest(url: url)
        request.setValue("Summon (macOS launcher; on-device AI)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebSearchError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebSearchError.network("HTTP \(http.statusCode)")
        }
        return Self.parse(data, host: host, limit: limit)
    }

    static func parse(_ data: Data, host: String, limit: Int) -> [WebHit] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = object["pages"] as? [[String: Any]] else { return [] }
        return pages.prefix(limit).compactMap { page in
            guard let title = page["title"] as? String else { return nil }
            let key = (page["key"] as? String) ?? title.replacingOccurrences(of: " ", with: "_")
            let description = (page["description"] as? String) ?? ""
            let excerpt = stripHTML((page["excerpt"] as? String) ?? "")
            let snippet = [description, excerpt].filter { !$0.isEmpty }.joined(separator: " — ")
            return WebHit(title: title, url: "https://\(host)/wiki/\(key)", snippet: snippet)
        }
    }

    static func stripHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Authorized test double — no network; carries a host for the egress journal.
public struct FakeAuthorizedWebSearchProvider: AuthorizedWebSearchProvider, Sendable {
    public let host: String
    public var hits: [WebHit]

    public init(
        host: String = "example.com",
        hits: [WebHit] = [WebHit(title: "Example", url: "https://example.com", snippet: "Example domain")]
    ) {
        self.host = host
        self.hits = hits
    }

    public func search(
        query: String,
        limit: Int,
        authorization: EgressAuthorization?
    ) async throws -> [WebHit] {
        _ = (query, authorization)
        return Array(hits.prefix(limit))
    }
}

public enum WebEnrich {
    /// Clean a natural-language question into a bare search query — strips
    /// conversational lead-ins that pollute keyword search (e.g. Wikipedia
    /// returned no results for "quick, what is quantum computing").
    public static func searchQuery(from question: String) -> String {
        var query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "tell me about ", "what do you know about ", "quick, ", "quick ",
            "can you explain ", "explain ", "please ", "hey, ", "so, ", "so ",
        ]
        var lowered = query.lowercased()
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where lowered.hasPrefix(prefix) {
                query = String(query.dropFirst(prefix.count))
                lowered = query.lowercased()
                changed = true
                break
            }
        }
        return query.isEmpty ? question : query
    }

    /// Build a prompt for L1/L0 from hits + question.
    public static func enrichPrompt(question: String, hits: [WebHit]) -> String {
        var lines = [
            "Answer the question using only the sources below. Cite titles. Be concise.",
            "You are ONLY answering a question from web results. You cannot perform, "
                + "stage, set, change, create, open, or do anything on this Mac, and you "
                + "must NEVER claim you did or that anything was staged. If the sources "
                + "do not answer the question, say so plainly.",
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
