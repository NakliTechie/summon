import Foundation

/// Whole-tree file-name index, stored as parallel arrays (struct of arrays) so
/// the search loops touch only plain integers and bytes.
///
/// Entries are laid out so each directory's children sit in one contiguous run
/// (`firstChild` / `childCount`). Entries added later by the watcher are
/// appended at the end and linked through `extraChildren`; `compacted()`
/// restores the contiguous layout before a snapshot is written.
///
/// Distinct names are stored once (`nameOffset` into `nameBytes`), so a query
/// scores `index.js` once however many folders hold one.
final class FileNameIndex: @unchecked Sendable {
    static let directoryFlag: UInt8 = 1
    static let symlinkFlag: UInt8 = 2
    static let deletedFlag: UInt8 = 0x80

    // Entries
    var parent: [Int32] = []
    var nameID: [Int32] = []
    var flags: [UInt8] = []
    /// Seconds since 1970; 0 when unknown.
    var mtime: [UInt32] = []
    var firstChild: [Int32] = []
    var childCount: [Int32] = []
    var extraChildren: [Int32: [Int32]] = [:]

    // Distinct names
    var nameBytes: [UInt8] = []
    /// ASCII-lowercased copy of `nameBytes`, same offsets.
    var lowerBytes: [UInt8] = []
    var nameOffset: [UInt32] = [0]
    /// Character bag per name (see `FuzzyMatcher.bag`), for cheap rejection.
    var nameBag: [UInt64] = []
    private var internTable: [String: Int32] = [:]

    /// Absolute paths of the crawl roots; root entries carry these as names.
    var roots: [String] = []
    /// FSEvents id taken just before the crawl, so replay covers changes made during it.
    var eventID: UInt64 = 0
    var builtAt: Date = .distantPast

    var entryCount: Int { parent.count }
    var nameCount: Int { nameOffset.count - 1 }

    var liveEntryCount: Int {
        flags.reduce(0) { $0 + ($1 & Self.deletedFlag == 0 ? 1 : 0) }
    }

    // MARK: Names

    func intern(_ name: String) -> Int32 {
        if let id = internTable[name] { return id }
        let id = Int32(nameCount)
        let bytes = Array(name.utf8)
        nameBytes.append(contentsOf: bytes)
        lowerBytes.append(contentsOf: bytes.map(FuzzyMatcher.lower))
        nameOffset.append(UInt32(nameBytes.count))
        nameBag.append(FuzzyMatcher.bag(bytes))
        internTable[name] = id
        return id
    }

    /// Frees the build-time intern table; later names are appended without dedup.
    func dropInternTable() {
        internTable = [:]
    }

    func nameRange(_ id: Int32) -> Range<Int> {
        Int(nameOffset[Int(id)])..<Int(nameOffset[Int(id) + 1])
    }

    func name(ofEntry entry: Int32) -> String {
        let range = nameRange(nameID[Int(entry)])
        return String(bytes: nameBytes[range], encoding: .utf8) ?? ""
    }

    // MARK: Entries

    @discardableResult
    func appendEntry(parent p: Int32, name: String, flags f: UInt8, mtime m: UInt32) -> Int32 {
        let index = Int32(entryCount)
        parent.append(p)
        nameID.append(intern(name))
        flags.append(f)
        mtime.append(m)
        firstChild.append(-1)
        childCount.append(0)
        return index
    }

    func isDirectory(_ entry: Int32) -> Bool { flags[Int(entry)] & Self.directoryFlag != 0 }
    func isDeleted(_ entry: Int32) -> Bool { flags[Int(entry)] & Self.deletedFlag != 0 }

    func children(of entry: Int32) -> [Int32] {
        var result: [Int32] = []
        let first = firstChild[Int(entry)]
        if first >= 0 {
            for i in first..<(first + childCount[Int(entry)]) where !isDeleted(i) {
                result.append(i)
            }
        }
        if let extra = extraChildren[entry] {
            result.append(contentsOf: extra.filter { !isDeleted($0) })
        }
        return result
    }

    func path(of entry: Int32) -> String {
        var parts: [String] = []
        var cursor = entry
        while cursor >= 0 {
            // Root entries store their absolute path as their name.
            parts.append(name(ofEntry: cursor))
            cursor = parent[Int(cursor)]
        }
        let reversed = parts.reversed()
        guard let root = reversed.first else { return "" }
        let tail = reversed.dropFirst().joined(separator: "/")
        if tail.isEmpty { return root }
        return root == "/" ? "/" + tail : root + "/" + tail
    }

    /// Resolves an absolute path to its entry, or nil when it is not indexed.
    func entry(forPath path: String) -> Int32? {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for (rootEntry, root) in rootEntries() {
            if normalized == root { return rootEntry }
            let prefix = root == "/" ? "/" : root + "/"
            guard normalized.hasPrefix(prefix) else { continue }
            var cursor = rootEntry
            for component in normalized.dropFirst(prefix.count).split(separator: "/") {
                guard let next = children(of: cursor).first(where: { name(ofEntry: $0) == component }) else {
                    return nil
                }
                cursor = next
            }
            return cursor
        }
        return nil
    }

    func rootEntries() -> [(Int32, String)] {
        var result: [(Int32, String)] = []
        for i in 0..<entryCount where parent[i] < 0 && !isDeleted(Int32(i)) {
            result.append((Int32(i), name(ofEntry: Int32(i))))
        }
        return result
    }

    func markDeleted(subtree entry: Int32) {
        var stack = [entry]
        while let e = stack.popLast() {
            stack.append(contentsOf: children(of: e))
            flags[Int(e)] |= Self.deletedFlag
        }
    }

    // MARK: Compaction

    /// Rebuilds the contiguous breadth-first layout without tombstones.
    func compacted() -> FileNameIndex {
        let out = FileNameIndex()
        out.roots = roots
        out.eventID = eventID
        out.builtAt = builtAt
        var queue: [(old: Int32, new: Int32)] = []
        for (rootEntry, rootPath) in rootEntries() {
            let new = out.appendEntry(parent: -1, name: rootPath, flags: flags[Int(rootEntry)], mtime: mtime[Int(rootEntry)])
            queue.append((rootEntry, new))
        }
        var head = 0
        while head < queue.count {
            let (old, new) = queue[head]
            head += 1
            let kids = children(of: old)
            guard !kids.isEmpty else { continue }
            out.firstChild[Int(new)] = Int32(out.entryCount)
            out.childCount[Int(new)] = Int32(kids.count)
            for kid in kids {
                let added = out.appendEntry(parent: new, name: name(ofEntry: kid), flags: flags[Int(kid)], mtime: mtime[Int(kid)])
                if isDirectory(kid) { queue.append((kid, added)) }
            }
        }
        out.dropInternTable()
        return out
    }

    // MARK: Snapshot

    private static let magic: UInt32 = 0x4946_4D53 // "SMFI"
    private static let version: UInt32 = 1

    func write(to url: URL) throws {
        var data = Data()
        func put<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        func putArray<T>(_ array: [T]) {
            put(UInt64(array.count))
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        put(Self.magic)
        put(Self.version)
        put(eventID)
        put(builtAt.timeIntervalSince1970)
        let rootsData = try JSONEncoder().encode(roots)
        putArray(Array(rootsData))
        putArray(parent)
        putArray(nameID)
        putArray(flags)
        putArray(mtime)
        putArray(firstChild)
        putArray(childCount)
        putArray(nameBytes)
        putArray(lowerBytes)
        putArray(nameOffset)
        putArray(nameBag)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(from url: URL) throws -> FileNameIndex {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var cursor = 0
        func take<T>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard cursor + size <= data.count else { throw CoreError.io("file index snapshot truncated") }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
            cursor += size
            return value
        }
        func takeArray<T>(_: T.Type) throws -> [T] {
            let count = Int(try take(UInt64.self))
            let bytes = count * MemoryLayout<T>.stride
            guard count >= 0, cursor + bytes <= data.count else { throw CoreError.io("file index snapshot truncated") }
            let array = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    let source = UnsafeRawBufferPointer(rebasing: raw[cursor..<(cursor + bytes)])
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: source)
                }
                initialized = count
            }
            cursor += bytes
            return array
        }
        guard try take(UInt32.self) == magic else { throw CoreError.io("not a Summon file index snapshot") }
        guard try take(UInt32.self) == version else { throw CoreError.io("file index snapshot version mismatch") }
        let index = FileNameIndex()
        index.eventID = try take(UInt64.self)
        index.builtAt = Date(timeIntervalSince1970: try take(Double.self))
        index.roots = try JSONDecoder().decode([String].self, from: Data(try takeArray(UInt8.self)))
        index.parent = try takeArray(Int32.self)
        index.nameID = try takeArray(Int32.self)
        index.flags = try takeArray(UInt8.self)
        index.mtime = try takeArray(UInt32.self)
        index.firstChild = try takeArray(Int32.self)
        index.childCount = try takeArray(Int32.self)
        index.nameBytes = try takeArray(UInt8.self)
        index.lowerBytes = try takeArray(UInt8.self)
        index.nameOffset = try takeArray(UInt32.self)
        index.nameBag = try takeArray(UInt64.self)
        let n = index.entryCount
        guard index.nameID.count == n, index.flags.count == n, index.mtime.count == n,
              index.firstChild.count == n, index.childCount.count == n,
              index.lowerBytes.count == index.nameBytes.count,
              index.nameBag.count == index.nameCount else {
            throw CoreError.io("file index snapshot is inconsistent")
        }
        return index
    }
}
