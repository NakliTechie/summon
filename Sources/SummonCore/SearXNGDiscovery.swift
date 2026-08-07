import Foundation

/// Port-resilient SearXNG discovery. `searxng-up.sh` picks whatever loopback
/// port is free on a given run and writes the resulting base URL here; the app
/// reads it so it doesn't matter which port SearXNG landed on. Filesystem only
/// — no network primitive (egress stays in `WebSearch.swift`).
public enum SearXNGDiscovery {
    /// Where `searxng-up.sh` records the running instance's base URL.
    public static var discoveryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/summon/searxng.url")
    }

    /// The recorded base URL, if a run wrote one (loopback only). nil otherwise.
    public static func discoveredBaseURL(file: URL? = nil) -> String? {
        let url = file ?? discoveryFile
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let host = parsed.host,
              WebSearchConfig.isLoopbackHost(host) else { return nil }
        return trimmed
    }
}

/// One place that decides which web-search provider to use, shared by the app
/// and CLI: the user's explicitly-configured SearXNG, else an auto-discovered
/// one (any port), else the keyless Wikipedia floor.
public enum WebSearchProviderResolver {
    public static func resolve(webConfig: WebSearchConfig) -> AuthorizedWebSearchProvider {
        let configured = webConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return SearXNGClient(config: webConfig)
        }
        if let discovered = SearXNGDiscovery.discoveredBaseURL() {
            return SearXNGClient(config: WebSearchConfig(enabled: true, baseURL: discovered))
        }
        return WikipediaSearchClient()
    }
}
