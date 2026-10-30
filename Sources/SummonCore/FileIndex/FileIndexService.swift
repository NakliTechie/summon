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
    /// Watcher rescans list folders through this, so one that hangs is skipped.
    let rescanLister: BoundedLister

    public convenience init(snapshotURL: URL, roots: [String], exclusions: FileIndexExclusions) {
        self.init(snapshotURL: snapshotURL, roots: roots, exclusions: exclusions, listing: DirectoryLister.list)
    }

    init(
        snapshotURL: URL,
        roots: [String],
        exclusions: FileIndexExclusions,
        listing: @escaping FileCrawler.Lister,
        listingTimeout: TimeInterval = 5
    ) {
        self.snapshotURL = snapshotURL
        // FSEvents reports resolved paths (`/private/var/…`), so roots are resolved too.
        self.roots = roots.map(Self.resolvedPath)
        self.exclusions = exclusions
        self.rescanLister = BoundedLister(timeout: listingTimeout, listing: listing)
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
            // Changes replayed from history arrived before the watcher was stored.
            if dirty { scheduleAutosaveLocked() }
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
    /// or a full subtree recrawl when FSEvents coalesced. Three steps, so the lock
    /// is never held across file-system I/O: resolve each folder (locked, no I/O),
    /// list and crawl it into a detached tree (unlocked, each listing time-limited),
    /// then merge (locked). A listing that hangs now costs one abandoned thread and
    /// a log line, never a stuck save, search or Quit (the 2026-10-30 deadlock).
    func apply(_ changes: [FileIndexChange], lastEventID: UInt64) {
        var seen = Set<String>()
        var plans: [RescanPlan] = []
        for change in changes where seen.insert(change.path).inserted {
            guard let target = resolveTarget(change.path) else { continue }
            if let plan = scan(target, recursive: change.recursive) { plans.append(plan) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return }
        for plan in plans { merge(plan, into: index) }
        if lastEventID > index.eventID { index.eventID = lastEventID }
        dirty = true
        fileIndexLog.debug("apply: \(seen.count) folders, \(plans.count) merged, watching: \(self.watcher != nil)")
        scheduleAutosaveLocked()
    }

    /// While watching, changes reach the snapshot within this delay, so a crash
    /// loses at most this much (the next launch replays it from FSEvents anyway).
    static let autosaveDelay: TimeInterval = 300
    private var autosaveScheduled = false

    /// Call with `lock` held.
    private func scheduleAutosaveLocked() {
        guard watcher != nil, !autosaveScheduled else { return }
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

    /// A changed folder resolved against the index, with what the index held for it.
    private struct RescanTarget {
        let path: String
        let existing: [String: Bool] // child name → is a directory
    }

    private enum RescanPlan {
        case gone(path: String)
        case replace(path: String, tree: FileNameIndex)
        case update(path: String, mtimes: [String: UInt32], removed: Set<String>, added: FileNameIndex)
    }

    /// Locked, no I/O: the nearest indexed folder for `path` and its current children.
    private func resolveTarget(_ path: String) -> RescanTarget? {
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return nil }
        var target = path
        var entry = index.entry(forPath: target)
        // A folder the index has never seen: rescan the nearest indexed ancestor.
        while entry == nil || !index.isDirectory(entry ?? 0) {
            guard target != "/", let slash = target.lastIndex(of: "/") else { return nil }
            target = slash == target.startIndex ? "/" : String(target[..<slash])
            entry = index.entry(forPath: target)
        }
        guard let dir = entry else { return nil }
        var existing: [String: Bool] = [:]
        for child in index.children(of: dir) { existing[index.name(ofEntry: child)] = index.isDirectory(child) }
        return RescanTarget(path: target, existing: existing)
    }

    /// Unlocked: lists the folder and crawls new subtrees into detached trees.
    /// Nil when the listing timed out, so a hung folder is never read as deleted.
    private func scan(_ target: RescanTarget, recursive: Bool) -> RescanPlan? {
        let listed: [CrawledChild]
        switch rescanLister.list(target.path) {
        case .timedOut: return nil
        case .unreadable: return .gone(path: target.path)
        case .listed(let children): listed = children
        }
        let scope = exclusions.honourIgnoreFiles ? IgnoreScope.enclosing(directory: target.path) : nil
        let filter = ChildFilter(exclusions: exclusions)
        let kept = listed.filter { filter.keep($0, in: target.path, scope: scope) }
        let lister = rescanLister
        let crawl = { (children: [CrawledChild]) in
            FileCrawler.crawlDetached(
                children, parentPath: target.path, scope: scope, exclusions: self.exclusions,
                lister: { lister.children($0) }
            )
        }
        if recursive { return .replace(path: target.path, tree: crawl(kept)) }

        var mtimes: [String: UInt32] = [:]
        var added: [CrawledChild] = []
        for child in kept {
            if target.existing[child.name] == child.isDirectory {
                mtimes[child.name] = child.mtime
            } else {
                added.append(child)
            }
        }
        // Gone, or a file that became a folder (or back): drop the old entry.
        let removed = Set(target.existing.keys.filter { mtimes[$0] == nil })
        return .update(path: target.path, mtimes: mtimes, removed: removed, added: crawl(added))
    }

    /// Locked: applies a plan, re-resolving the folder by path because autosave
    /// may have compacted the index (new entry numbers) since it was resolved.
    private func merge(_ plan: RescanPlan, into index: FileNameIndex) {
        switch plan {
        case .gone(let path):
            if let entry = index.entry(forPath: path), index.parent[Int(entry)] >= 0 {
                index.markDeleted(subtree: entry)
            }
        case .replace(let path, let tree):
            guard let dir = index.entry(forPath: path), index.isDirectory(dir) else { return }
            for child in index.children(of: dir) { index.markDeleted(subtree: child) }
            index.extraChildren[dir] = nil
            index.graft(tree, under: dir)
        case .update(let path, let mtimes, let removed, let added):
            guard let dir = index.entry(forPath: path), index.isDirectory(dir) else { return }
            for child in index.children(of: dir) {
                let name = index.name(ofEntry: child)
                if removed.contains(name) {
                    index.markDeleted(subtree: child)
                } else if let mtime = mtimes[name] {
                    index.mtime[Int(child)] = mtime
                }
            }
            index.graft(added, under: dir)
        }
    }

    // MARK: Search / status

    /// Nil when no index is loaded, or while a merge or compaction holds it: the
    /// caller falls back to Spotlight instead of blocking a keystroke.
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
