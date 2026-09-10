import Foundation

/// Port-resilient SearXNG discovery. `searxng-up.sh` picks whatever loopback
/// port is free on a given run and writes the resulting base URL here; the app
/// reads it so it doesn't matter which port SearXNG landed on. Filesystem only
/// — no network primitive (egress stays in `WebSearch.swift`).
public enum SearXNGDiscovery {
    /// Where `searxng-up.sh` records the running instance's base URL.
    ///
    /// Resolves `$HOME` exactly as the scripts do. `homeDirectoryForCurrentUser`
    /// ignores an overridden HOME, which made every isolated run (tests, agents,
    /// `make cli-e2e`) read — and on remove, delete — the real user's file.
    public static var discoveryFile: URL {
        let home: URL
        if let env = ProcessInfo.processInfo.environment["HOME"], !env.isEmpty {
            home = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".config/summon/searxng.url")
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

    /// Record the running instance's base URL (the same file `searxng-up.sh`
    /// writes). Loopback only; anything else is refused and leaves the file alone.
    public static func record(baseURL: String, file: URL? = nil) {
        guard let parsed = URL(string: baseURL), let host = parsed.host,
              WebSearchConfig.isLoopbackHost(host) else { return }
        let url = file ?? discoveryFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? (baseURL + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Forget the recorded instance (the backend was removed).
    public static func clear(file: URL? = nil) {
        try? FileManager.default.removeItem(at: file ?? discoveryFile)
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
