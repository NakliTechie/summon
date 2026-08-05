import Foundation

/// Scans local application directories for `.app` bundles (S1 / launcher core).
/// Scan results are cached — full FS walks on every keystroke were a major lag source.
public struct AppCatalog: Sendable {
    public struct AppEntry: Sendable, Hashable, Equatable {
        public let name: String
        public let path: String
        public let bundleID: String?

        public init(name: String, path: String, bundleID: String? = nil) {
            self.name = name
            self.path = path
            self.bundleID = bundleID
        }
    }

    public let searchPaths: [URL]
    /// How long a scan stays valid (seconds).
    public var cacheTTL: TimeInterval

    public init(searchPaths: [URL]? = nil, cacheTTL: TimeInterval = 60) {
        self.cacheTTL = cacheTTL
        if let searchPaths {
            self.searchPaths = searchPaths
        } else {
            let fm = FileManager.default
            var paths: [URL] = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                // System apps delivered via cryptex (Safari is a symlink into here).
                URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            ]
            paths.append(
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            )
            self.searchPaths = paths
        }
    }

    public func scan() -> [AppEntry] {
        AppCatalogCache.shared.apps(paths: searchPaths, ttl: cacheTTL) {
            self.scanUncached()
        }
    }

    /// Drop cached scan (tests / after install).
    public static func invalidateCache() {
        AppCatalogCache.shared.invalidate()
    }

    private func scanUncached() -> [AppEntry] {
        var apps: [AppEntry] = []
        var seenResolved = Set<String>()
        for root in searchPaths {
            collectApps(from: root, depth: 0, into: &apps, seenResolved: &seenResolved)
        }
        // Collapse cryptex + /Applications duplicates (same name / bundle).
        apps = Self.dedupePreferUserFacing(apps)
        apps = Self.preferApplicationsPath(apps)
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// If `/Applications/Name.app` exists (often a symlink to cryptex), use that path for open/icons.
    private static func preferApplicationsPath(_ apps: [AppEntry]) -> [AppEntry] {
        return apps.map { app in
            let candidates = [
                "/Applications/\(app.name).app",
                "/System/Applications/\(app.name).app",
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c) {
                return AppEntry(name: app.name, path: c, bundleID: app.bundleID)
            }
            return app
        }
    }

    /// Prefer `/Applications` (and shorter paths) over cryptex/preboot clones.
    private static func dedupePreferUserFacing(_ apps: [AppEntry]) -> [AppEntry] {
        func rank(_ path: String) -> Int {
            if path.hasPrefix("/Applications") { return 0 }
            if path.hasPrefix("/System/Applications") { return 1 }
            if path.contains("Cryptexes") || path.contains("Preboot") { return 3 }
            return 2
        }
        var best: [String: AppEntry] = [:]
        for app in apps {
            let key = (app.bundleID?.lowercased()).flatMap { $0.isEmpty ? nil : $0 }
                ?? app.name.lowercased()
            if let existing = best[key] {
                if rank(app.path) < rank(existing.path) {
                    best[key] = app
                }
            } else {
                best[key] = app
            }
        }
        return Array(best.values)
    }

    /// Recursive directory listing (not `enumerator` + `skipsPackageDescendants`).
    /// `FileManager.enumerator` skips symlink `.app` packages (e.g. Safari → cryptex).
    private func collectApps(
        from directory: URL,
        depth: Int,
        into apps: inout [AppEntry],
        seenResolved: inout Set<String>
    ) {
        // Don't descend forever (Applications is shallow; Utilities is depth 1).
        guard depth <= 3 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            if item.pathExtension == "app" {
                // Keep the path the user sees (/Applications/Safari.app); resolve only for dedupe.
                let path = item.path
                let resolved = item.resolvingSymlinksInPath().path
                if seenResolved.contains(resolved) { continue }
                seenResolved.insert(resolved)
                let name = item.deletingPathExtension().lastPathComponent
                let bundleURL = item.resolvingSymlinksInPath()
                let bundleID = Bundle(url: bundleURL)?.bundleIdentifier
                apps.append(AppEntry(name: name, path: path, bundleID: bundleID))
                continue
            }
            // Descend into folders that are not packages (e.g. Utilities, Xencelabs).
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isPackageKey])
            if values?.isPackage == true { continue }
            collectApps(from: item, depth: depth + 1, into: &apps, seenResolved: &seenResolved)
        }
    }

    public func search(query: FilterQuery, limit: Int = 50) -> [SearchResult] {
        let apps = scan()
        let q = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind = query.kind, kind != "app" && kind != "application" {
            return []
        }
        let filtered: [AppEntry]
        if q.isEmpty {
            filtered = Array(apps.prefix(limit))
        } else {
            // Full scan always — early-break on alphabetical order dropped Safari (and friends).
            var exact: [AppEntry] = []
            var prefix: [AppEntry] = []
            var word: [AppEntry] = [] // space-separated token prefix (e.g. "Store" in "App Store")
            var contains: [AppEntry] = []
            for app in apps {
                let lower = app.name.lowercased()
                if lower == q {
                    exact.append(app)
                } else if lower.hasPrefix(q) {
                    prefix.append(app)
                } else if Self.tokenPrefixMatch(name: lower, query: q) {
                    word.append(app)
                } else if q.count >= 2, lower.contains(q) {
                    // 1-char contains is noise ("s" matches almost everything).
                    contains.append(app)
                }
            }
            // Stable quality order: exact → prefix → word → contains; name A–Z within band.
            func byName(_ a: AppEntry, _ b: AppEntry) -> Bool {
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            let ordered =
                exact.sorted(by: byName)
                + prefix.sorted(by: byName)
                + word.sorted(by: byName)
                + contains.sorted(by: byName)
            filtered = Array(ordered.prefix(limit))
        }
        return filtered.enumerated().map { index, app in
            let score = scoreName(app.name, query: q, rank: index)
            return SearchResult(
                id: "app:\(app.path)",
                title: app.name,
                subtitle: app.path,
                kind: .app,
                path: app.path,
                score: score,
                payload: app.bundleID.map { ["bundleID": .string($0)] } ?? [:]
            )
        }
    }

    /// True if any whitespace-separated token has `query` as prefix (or equals).
    private static func tokenPrefixMatch(name: String, query: String) -> Bool {
        name.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .contains { $0.hasPrefix(query) }
    }

    private func scoreName(_ name: String, query: String, rank: Int) -> Double {
        if query.isEmpty { return Double(1000 - rank) }
        let lower = name.lowercased()
        // Large gaps so finalize kind-bands + residual keep relative order.
        if lower == query { return 1000 - Double(rank) * 0.01 }
        if lower.hasPrefix(query) { return 900 - Double(rank) * 0.01 }
        if Self.tokenPrefixMatch(name: lower, query: query) { return 850 - Double(rank) * 0.01 }
        if lower.contains(query) { return 700 - Double(rank) * 0.01 }
        return 100 - Double(rank)
    }
}

/// Process-wide app scan cache (paths key → entries + expiry).
private final class AppCatalogCache: @unchecked Sendable {
    static let shared = AppCatalogCache()
    private let lock = NSLock()
    private var entries: [AppCatalog.AppEntry] = []
    private var pathKey: String = ""
    private var expiresAt: Date = .distantPast

    func apps(
        paths: [URL],
        ttl: TimeInterval,
        build: () -> [AppCatalog.AppEntry]
    ) -> [AppCatalog.AppEntry] {
        let key = paths.map(\.path).joined(separator: "\n")
        lock.lock()
        if pathKey == key, Date() < expiresAt {
            let hit = entries
            lock.unlock()
            return hit
        }
        lock.unlock()
        let fresh = build()
        lock.lock()
        pathKey = key
        entries = fresh
        expiresAt = Date().addingTimeInterval(ttl)
        lock.unlock()
        return fresh
    }

    func invalidate() {
        lock.lock()
        entries = []
        pathKey = ""
        expiresAt = .distantPast
        lock.unlock()
    }
}
