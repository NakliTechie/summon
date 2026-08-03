import Foundation

/// Scans local application directories for `.app` bundles (S1 / launcher core).
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

    public init(searchPaths: [URL]? = nil) {
        if let searchPaths {
            self.searchPaths = searchPaths
        } else {
            let fm = FileManager.default
            var paths: [URL] = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            ]
            paths.append(
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            )
            self.searchPaths = paths
        }
    }

    public func scan() -> [AppEntry] {
        let fm = FileManager.default
        var apps: [AppEntry] = []
        var seen = Set<String>()
        for root in searchPaths {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                let path = url.path
                if seen.contains(path) { continue }
                seen.insert(path)
                let name = url.deletingPathExtension().lastPathComponent
                let bundleID = Bundle(url: url)?.bundleIdentifier
                apps.append(AppEntry(name: name, path: path, bundleID: bundleID))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            filtered = apps.filter { $0.name.lowercased().contains(q) }.prefix(limit).map { $0 }
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

    private func scoreName(_ name: String, query: String, rank: Int) -> Double {
        if query.isEmpty { return Double(1000 - rank) }
        let lower = name.lowercased()
        if lower == query { return 1000 }
        if lower.hasPrefix(query) { return 900 - Double(rank) }
        if lower.contains(query) { return 700 - Double(rank) }
        return 100 - Double(rank)
    }
}
