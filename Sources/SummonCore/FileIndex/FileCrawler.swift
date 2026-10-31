import Darwin
import Foundation

/// What the index leaves out, and why. Every skip is listed here so the
/// surface can say what it does not search (fff/fsearch lesson: an unlisted
/// skip reads as a fast index that misses files).
public struct FileIndexExclusions: Sendable, Equatable {
    /// Basenames never indexed, at any depth.
    public var names: Set<String>
    /// Absolute paths never entered.
    public var paths: Set<String>
    /// Inside a git repository, honour `.gitignore`, `.ignore` and `.git/info/exclude`.
    public var honourIgnoreFiles: Bool

    public init(names: Set<String>, paths: Set<String>, honourIgnoreFiles: Bool) {
        self.names = names
        self.paths = paths
        self.honourIgnoreFiles = honourIgnoreFiles
    }

    public static func standard(home: String = NSHomeDirectory()) -> FileIndexExclusions {
        FileIndexExclusions(
            // `Cache_Data` is the Chromium/Electron HTTP cache: thousands of hashed
            // names, and the app's open() on Claude's copy blocked past the 5 s limit.
            names: [".git", ".DS_Store", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", "Cache_Data"],
            paths: [
                home + "/.Trash",
                home + "/Library/Caches",
                // Other apps' sandbox data. Since macOS 15 an open() here waits on an
                // "access data from other apps" consent prompt instead of failing.
                home + "/Library/Containers",
                home + "/Library/Group Containers",
                home + "/Library/Daemon Containers",
                "/Volumes",
                "/System/Volumes",
                "/dev",
                "/private/var/folders",
                "/private/var/vm",
            ],
            honourIgnoreFiles: true
        )
    }

    /// One line per rule, for `files status` and the README.
    public var descriptionLines: [String] {
        var lines = ["names: " + names.sorted().joined(separator: ", ")]
        lines.append("paths: " + paths.sorted().joined(separator: ", "))
        lines.append(honourIgnoreFiles
            ? "inside git repositories: .gitignore, .ignore, .git/info/exclude"
            : "ignore files: not honoured")
        lines.append("symlinks: indexed by name, never followed")
        return lines
    }
}

/// One directory child as read by `getattrlistbulk`.
struct CrawledChild {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let mtime: UInt32
}

enum DirectoryLister {
    // sys/attr.h values, spelled out because some do not import as Swift constants.
    private static let attrBitMapCount: UInt16 = 5
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let vreg: UInt32 = 1
    private static let vdir: UInt32 = 2
    private static let vlnk: UInt32 = 5

    /// Lists one directory with a single bulk call per buffer (no per-file stat).
    /// Nil when the directory cannot be opened (permission, vanished).
    static func list(_ path: String) -> [CrawledChild]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = attrBitMapCount
        request.commonattr = attrgroup_t(cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnModTime)

        let bufferSize = 256 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var children: [CrawledChild] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { return children.isEmpty ? nil : children }
            if count == 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let child = parse(entry) { children.append(child) }
                entry += length
            }
        }
        return children
    }

    private static func parse(_ entry: UnsafeMutableRawPointer) -> CrawledChild? {
        var field = entry + 4
        // attribute_set_t: common, vol, dir, file, fork (5 × UInt32)
        let returned = field.loadUnaligned(as: UInt32.self)
        field += 20
        if returned & cmnError != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return nil }
        }
        guard returned & cmnName != 0 else { return nil }
        let nameOffset = Int(field.loadUnaligned(as: Int32.self))
        // NUL-terminated; String(cString:) repairs any invalid UTF-8.
        let name = String(cString: (field + nameOffset).assumingMemoryBound(to: CChar.self))
        field += 8
        var objectType: UInt32 = 0
        if returned & cmnObjType != 0 {
            objectType = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var mtime: UInt32 = 0
        if returned & cmnModTime != 0 {
            let seconds = field.loadUnaligned(as: Int.self)
            mtime = UInt32(clamping: max(0, seconds))
        }
        guard objectType == vreg || objectType == vdir || objectType == vlnk else {
            // Sockets, fifos, devices: not files a launcher opens.
            return objectType == 0 ? CrawledChild(name: name, isDirectory: false, isSymlink: false, mtime: mtime) : nil
        }
        return CrawledChild(name: name, isDirectory: objectType == vdir, isSymlink: objectType == vlnk, mtime: mtime)
    }
}

/// Filters one directory's children through the exclusions and ignore scope,
/// and returns the scope its subdirectories inherit.
struct ChildFilter {
    let exclusions: FileIndexExclusions

    func scope(for directory: String, children: [CrawledChild], inherited: IgnoreScope?) -> IgnoreScope? {
        guard exclusions.honourIgnoreFiles else { return nil }
        let isRepoRoot = children.contains { $0.name == ".git" }
        let hasIgnoreFile = children.contains { IgnoreScope.ignoreFileNames.contains($0.name) }
        if isRepoRoot {
            return IgnoreScope(
                directory: directory,
                rules: IgnoreScope.loadRules(in: directory, includeGitInfoExclude: true),
                parent: nil
            )
        }
        if let inherited, hasIgnoreFile {
            return IgnoreScope(
                directory: directory,
                rules: IgnoreScope.loadRules(in: directory, includeGitInfoExclude: false),
                parent: inherited
            )
        }
        return inherited
    }

    func keep(_ child: CrawledChild, in directory: String, scope: IgnoreScope?) -> Bool {
        if exclusions.names.contains(child.name) { return false }
        let path = directory == "/" ? "/" + child.name : directory + "/" + child.name
        if child.isDirectory, exclusions.paths.contains(path) { return false }
        if let scope, scope.isIgnored(path: Array(path.utf8), basename: Array(child.name.utf8), isDirectory: child.isDirectory) {
            return false
        }
        return true
    }
}

/// Parallel breadth-first crawl into a `FileNameIndex`. Workers list
/// directories concurrently; one lock appends each directory's children as a
/// contiguous run, so the layout stays folder-ordered whatever order the
/// listings finish in.
final class FileCrawler: @unchecked Sendable {
    /// Lists one directory; nil when it cannot be read.
    typealias Lister = @Sendable (String) -> [CrawledChild]?

    struct Job {
        let entry: Int32
        let path: String
        let scope: IgnoreScope?
    }

    private let index: FileNameIndex
    private let filter: ChildFilter
    private let lister: Lister
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var inFlight = 0
    private(set) var unreadable: [String] = []

    init(index: FileNameIndex, exclusions: FileIndexExclusions, lister: @escaping Lister = DirectoryLister.list) {
        self.index = index
        self.filter = ChildFilter(exclusions: exclusions)
        self.lister = lister
    }

    /// Crawls fresh roots into an empty index.
    static func build(
        roots: [String],
        exclusions: FileIndexExclusions,
        lister: @escaping Lister = DirectoryLister.list
    ) -> (FileNameIndex, unreadable: [String]) {
        let index = FileNameIndex()
        index.roots = roots
        index.eventID = FileIndexWatcher.currentEventID()
        index.builtAt = Date()
        let crawler = FileCrawler(index: index, exclusions: exclusions, lister: lister)
        var seeds: [Job] = []
        for root in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            let entry = index.appendEntry(parent: -1, name: root, flags: FileNameIndex.directoryFlag, mtime: 0)
            seeds.append(Job(entry: entry, path: root, scope: exclusions.honourIgnoreFiles ? IgnoreScope.enclosing(directory: root) : nil))
        }
        crawler.run(seeds)
        index.dropInternTable()
        return (index, crawler.unreadable)
    }

    /// Crawls below existing directory entries (watcher: a new or rescanned subtree).
    func run(_ seeds: [Job]) {
        condition.lock()
        jobs.append(contentsOf: seeds)
        condition.unlock()
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in self.work() }
    }

    private func work() {
        while true {
            condition.lock()
            while jobs.isEmpty && inFlight > 0 { condition.wait() }
            guard let job = jobs.popLast() else {
                condition.unlock()
                condition.broadcast()
                return
            }
            inFlight += 1
            condition.unlock()

            let listed = lister(job.path)
            var kept: [CrawledChild] = []
            var scope = job.scope
            if let listed {
                scope = filter.scope(for: job.path, children: listed, inherited: job.scope)
                kept = listed.filter { filter.keep($0, in: job.path, scope: scope) }
            }

            condition.lock()
            if listed == nil { unreadable.append(job.path) }
            if !kept.isEmpty {
                index.firstChild[Int(job.entry)] = Int32(index.entryCount)
                index.childCount[Int(job.entry)] = Int32(kept.count)
                for child in kept {
                    let entry = index.appendEntry(parent: job.entry, name: child.name, flags: child.indexFlags, mtime: child.mtime)
                    if child.isDirectory {
                        let childPath = job.path == "/" ? "/" + child.name : job.path + "/" + child.name
                        jobs.append(Job(entry: entry, path: childPath, scope: scope))
                    }
                }
            }
            inFlight -= 1
            condition.unlock()
            condition.broadcast()
        }
    }

    /// Crawls `children` of `parentPath` into a detached index whose top entries
    /// are those children (parent -1), for `FileNameIndex.graft`. The live index is
    /// not touched, so the watcher can do this I/O without holding its lock.
    static func crawlDetached(
        _ children: [CrawledChild],
        parentPath: String,
        scope: IgnoreScope?,
        exclusions: FileIndexExclusions,
        lister: @escaping Lister
    ) -> FileNameIndex {
        let tree = FileNameIndex()
        let crawler = FileCrawler(index: tree, exclusions: exclusions, lister: lister)
        var seeds: [Job] = []
        for child in children where crawler.filter.keep(child, in: parentPath, scope: scope) {
            let entry = tree.appendEntry(parent: -1, name: child.name, flags: child.indexFlags, mtime: child.mtime)
            if child.isDirectory {
                let childPath = parentPath == "/" ? "/" + child.name : parentPath + "/" + child.name
                seeds.append(Job(entry: entry, path: childPath, scope: scope))
            }
        }
        if !seeds.isEmpty { crawler.run(seeds) }
        return tree
    }
}

extension CrawledChild {
    var indexFlags: UInt8 {
        var flags: UInt8 = 0
        if isDirectory { flags |= FileNameIndex.directoryFlag }
        if isSymlink { flags |= FileNameIndex.symlinkFlag }
        return flags
    }
}

enum BoundedListing {
    case listed([CrawledChild])
    case unreadable
    case timedOut
}

/// Runs each directory listing with a time limit. On macOS 26 an `open()` can
/// block indefinitely (another app's sandbox data, 2026-10-11; the app's live
/// pass, 2026-10-30). The waiting thread is abandoned, the path is logged and
/// remembered, and later listings of it return at once.
final class BoundedLister: @unchecked Sendable {
    let timeout: TimeInterval
    private let listing: FileCrawler.Lister
    private let lock = NSLock()
    private var blocked = Set<String>()

    init(timeout: TimeInterval, listing: @escaping FileCrawler.Lister) {
        self.timeout = timeout
        self.listing = listing
    }

    var blockedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func list(_ path: String) -> BoundedListing {
        lock.lock()
        let known = blocked.contains(path)
        lock.unlock()
        if known { return .timedOut }

        let done = DispatchSemaphore(value: 0)
        let box = ListingBox()
        let listing = self.listing
        DispatchQueue.global(qos: .utility).async {
            box.value = listing(path)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            blocked.insert(path)
            lock.unlock()
            fileIndexLog.error("listing blocked over \(self.timeout, format: .fixed(precision: 1)) s, skipped: \(path, privacy: .public)")
            return .timedOut
        }
        return box.value.map { .listed($0) } ?? .unreadable
    }

    /// The crawler's view: a blocked or unreadable folder has no children.
    func children(_ path: String) -> [CrawledChild]? {
        if case .listed(let children) = list(path) { return children }
        return nil
    }
}

private final class ListingBox: @unchecked Sendable {
    var value: [CrawledChild]?
}
