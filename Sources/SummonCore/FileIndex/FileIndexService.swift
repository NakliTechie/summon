import Foundation
import os

/// Lifecycle events of the file index, so a stalled watcher or a failed save is
/// visible: `log stream --predicate 'subsystem == "tech.nakli.Summon"'`.
let fileIndexLog = Logger(subsystem: "tech.nakli.Summon", category: "fileindex")

/// Owns the file-name index: build, snapshot, catch-up on restart, live
/// watching, and search. Off by default (`search.files.index.enabled`);
/// Spotlight stays the floor until it is enabled and built.
public final class FileIndexService: @unchecked Sendable {
    public static let enabledSettingKey = "search.files.index.enabled"
    public static let snapshotFileName = "file-index.bin"

    public struct BuildReport: Sendable {
        public let entries: Int
        public let distinctNames: Int
        public let seconds: Double
        public let unreadable: [String]
    }

    public struct Status: Sendable {
        public let loaded: Bool
        public let entries: Int
        public let distinctNames: Int
        public let roots: [String]
        public let builtAt: Date?
        public let snapshotBytes: Int?
        public let watching: Bool
        public let exclusions: [String]
    }

    public let snapshotURL: URL
    public let roots: [String]
    public let exclusions: FileIndexExclusions

    private let lock = NSLock()
    private var index: FileNameIndex?
    private var watcher: FileIndexWatcher?
    private var dirty = false

    public init(snapshotURL: URL, roots: [String], exclusions: FileIndexExclusions) {
        self.snapshotURL = snapshotURL
        // FSEvents reports resolved paths (`/private/var/…`), so roots are resolved too.
        self.roots = roots.map(Self.resolvedPath)
        self.exclusions = exclusions
    }

    /// Default: the user's home folder, standard exclusions, snapshot in the Summon container.
    public static func standard(container: URL, home: String = NSHomeDirectory()) -> FileIndexService {
        FileIndexService(
            snapshotURL: container.appendingPathComponent(snapshotFileName),
            roots: [home],
            exclusions: .standard(home: home)
        )
    }

    static func resolvedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { return (expanded as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return index != nil
    }

    // MARK: Build / load / save

    @discardableResult
    public func build() throws -> BuildReport {
        let start = Date()
        let (built, unreadable) = FileCrawler.build(roots: roots, exclusions: exclusions)
        let seconds = Date().timeIntervalSince(start)
        try built.write(to: snapshotURL)
        lock.lock()
        index = built
        dirty = false
        lock.unlock()
        return BuildReport(entries: built.entryCount, distinctNames: built.nameCount, seconds: seconds, unreadable: unreadable)
    }

    /// Loads the snapshot. False when there is none or it was built for other roots.
    @discardableResult
    public func load() throws -> Bool {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            fileIndexLog.info("load: no snapshot")
            return false
        }
        let loaded = try FileNameIndex.read(from: snapshotURL)
        guard loaded.roots == roots else {
            fileIndexLog.error("load: snapshot roots \(loaded.roots, privacy: .public) differ from \(self.roots, privacy: .public)")
            return false
        }
        lock.lock()
        index = loaded
        dirty = false
        lock.unlock()
        fileIndexLog.info("load: \(loaded.entryCount) entries, event id \(loaded.eventID)")
        return true
    }

    private var loadAttempted = false

    /// One load attempt per process, for callers that search without starting the service.
    public func loadOnceIfNeeded() {
        lock.lock()
        let attempt = index == nil && !loadAttempted
        loadAttempted = true
        lock.unlock()
        if attempt { _ = try? load() }
    }

    public func saveIfDirty() throws {
        lock.lock()
        guard dirty, let current = index else {
            lock.unlock()
            return
        }
        let compacted = current.compacted()
        index = compacted
        dirty = false
        lock.unlock()
        do {
            try compacted.write(to: snapshotURL)
            fileIndexLog.info("save: \(compacted.entryCount) entries, event id \(compacted.eventID)")
        } catch {
            fileIndexLog.error("save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: Watching

    /// Replays FSEvents history since the snapshot, then keeps watching when
    /// `keepWatching`. Returns false when history did not finish in time.
    @discardableResult
    public func catchUp(keepWatching: Bool, timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        let since = index?.eventID
        lock.unlock()
        guard let since else { return false }
        stopWatching()
        let watcher = FileIndexWatcher { [weak self] changes, lastID in
            self?.apply(changes, lastEventID: lastID)
        }
        guard watcher.start(roots: roots, since: since) else {
            fileIndexLog.error("watch: FSEvents stream did not start (since \(since))")
            return false
        }
        let started = Date()
        let finished = watcher.waitForHistory(timeout: timeout)
        let waited = Date().timeIntervalSince(started)
        let outcome = finished ? "replayed" : "timed out"
        fileIndexLog.info(
            "watch: history \(outcome, privacy: .public) after \(waited, format: .fixed(precision: 1)) s; keep: \(keepWatching)"
        )
        if keepWatching {
            lock.lock()
            self.watcher = watcher
            lock.unlock()
        } else {
            watcher.stop()
        }
        return finished
    }

    public func stopWatching() {
        lock.lock()
        let current = watcher
        watcher = nil
        lock.unlock()
        current?.stop()
    }

    /// Applies directory-level changes: a shallow rescan of each changed folder,
    /// or a full subtree recrawl when FSEvents coalesced.
    func apply(_ changes: [FileIndexChange], lastEventID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return }
        let crawler = FileCrawler(index: index, exclusions: exclusions)
        var seen = Set<String>()
        for change in changes where seen.insert(change.path).inserted {
            rescan(change.path, recursive: change.recursive, index: index, crawler: crawler)
        }
        if lastEventID > index.eventID { index.eventID = lastEventID }
        dirty = true
        fileIndexLog.debug("apply: \(seen.count) folders, watching: \(self.watcher != nil), autosave pending: \(self.autosaveScheduled)")
        if watcher != nil, !autosaveScheduled {
            fileIndexLog.info("autosave scheduled in \(Self.autosaveDelay, format: .fixed(precision: 0)) s")
            autosaveScheduled = true
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.autosaveDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.autosaveScheduled = false
                self.lock.unlock()
                try? self.saveIfDirty()
            }
        }
    }

    /// While watching, changes reach the snapshot within this delay, so a crash
    /// loses at most this much (the next launch replays it from FSEvents anyway).
    static let autosaveDelay: TimeInterval = 300
    private var autosaveScheduled = false

    private func rescan(_ path: String, recursive: Bool, index: FileNameIndex, crawler: FileCrawler) {
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return }
        var target = path
        var entry = index.entry(forPath: target)
        // A folder the index has never seen: rescan the nearest indexed ancestor.
        while entry == nil || !index.isDirectory(entry ?? 0) {
            guard target != "/", let slash = target.lastIndex(of: "/") else { return }
            target = slash == target.startIndex ? "/" : String(target[..<slash])
            entry = index.entry(forPath: target)
        }
        guard let dir = entry else { return }
        let scope = exclusions.honourIgnoreFiles ? IgnoreScope.enclosing(directory: target) : nil
        guard let listed = DirectoryLister.list(target) else {
            if index.parent[Int(dir)] >= 0 { index.markDeleted(subtree: dir) }
            return
        }
        let filter = crawler.childFilter()
        let kept = listed.filter { filter.keep($0, in: target, scope: scope) }
        if recursive {
            for child in index.children(of: dir) { index.markDeleted(subtree: child) }
            index.extraChildren[dir] = nil
            crawler.appendLater(kept, under: dir, parentPath: target, scope: scope)
            return
        }
        var existing: [String: Int32] = [:]
        for child in index.children(of: dir) { existing[index.name(ofEntry: child)] = child }
        var added: [CrawledChild] = []
        for child in kept {
            if let old = existing.removeValue(forKey: child.name) {
                if index.isDirectory(old) == child.isDirectory {
                    index.mtime[Int(old)] = child.mtime
                    continue
                }
                index.markDeleted(subtree: old)
            }
            added.append(child)
        }
        for (_, gone) in existing { index.markDeleted(subtree: gone) }
        if !added.isEmpty { crawler.appendLater(added, under: dir, parentPath: target, scope: scope) }
    }

    // MARK: Search / status

    /// Nil when no index is loaded, or while a watcher update holds it (a large
    /// subtree recrawl): the caller falls back to Spotlight instead of blocking a keystroke.
    public func search(query: FilterQuery, limit: Int) -> [SearchResult]? {
        guard lock.lock(before: Date().addingTimeInterval(0.05)) else { return nil }
        defer { lock.unlock() }
        guard let index else { return nil }
        var query = query
        if let scope = query.pathPrefix {
            // `in:` paths arrive unresolved (`/var/…`, `~/…`); the index stores resolved ones.
            let resolved = Self.resolvedPath(scope)
            query = FilterQuery(
                freeText: query.freeText,
                filters: query.filters.map { if case .path = $0 { return .path(resolved) } else { return $0 } }
            )
        }
        return FileIndexSearch.search(index, query: query, limit: limit)
    }

    public func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? Int) ?? nil
        return Status(
            loaded: index != nil,
            entries: index?.liveEntryCount ?? 0,
            distinctNames: index?.nameCount ?? 0,
            roots: roots,
            builtAt: index?.builtAt,
            snapshotBytes: size,
            watching: watcher != nil,
            exclusions: exclusions.descriptionLines
        )
    }
}

/// `SpotlightIndexing` backed by the file index, falling back to Spotlight
/// (`mdfind`) while the index is not loaded.
public struct IndexedFileSearch: SpotlightIndexing, Sendable {
    public let service: FileIndexService
    public let fallback: any SpotlightIndexing

    public init(service: FileIndexService, fallback: any SpotlightIndexing = MdfindSpotlightIndex()) {
        self.service = service
        self.fallback = fallback
    }

    public func search(query: FilterQuery, limit: Int) throws -> [SearchResult] {
        service.loadOnceIfNeeded()
        if let results = service.search(query: query, limit: limit) { return results }
        return try fallback.search(query: query, limit: limit)
    }
}
