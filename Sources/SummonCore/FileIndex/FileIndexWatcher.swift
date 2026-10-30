import CoreServices
import Foundation

/// One FSEvents change, reduced to what the index needs.
struct FileIndexChange: Equatable {
    let path: String
    /// The kernel or daemon coalesced events: rescan the whole subtree.
    let recursive: Bool
}

/// Directory-level FSEvents stream over the index roots. Replays history from
/// a saved event id (so a restart applies only what changed while Summon was
/// not running), then keeps delivering changes until stopped.
final class FileIndexWatcher: @unchecked Sendable {
    typealias Handler = (_ changes: [FileIndexChange], _ lastEventID: UInt64) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "summon.fileindex.watcher", qos: .utility)
    private let handler: Handler
    private let historyDone = DispatchSemaphore(value: 0)
    private var historySignalled = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Starts the stream. With `since` set, history is replayed first and
    /// `waitForHistory` returns once the replay has been delivered.
    func start(roots: [String], since eventID: UInt64?, latency: TimeInterval = 0.3) -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let watcher = Unmanaged<FileIndexWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            watcher.deliver(count: count, paths: paths, flags: rawFlags, ids: rawIDs)
        }
        let sinceWhen = eventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, roots as CFArray, sinceWhen, latency, flags
        ) else { return false }
        stream = created
        if eventID == nil { signalHistoryDone() }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            return false
        }
        return true
    }

    /// Blocks until the replayed history has been handled, or the timeout passes.
    @discardableResult
    func waitForHistory(timeout: TimeInterval) -> Bool {
        historyDone.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func signalHistoryDone() {
        guard !historySignalled else { return }
        historySignalled = true
        historyDone.signal()
    }

    private func deliver(
        count: Int,
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        ids: UnsafePointer<FSEventStreamEventId>
    ) {
        var changes: [FileIndexChange] = []
        var lastID: UInt64 = 0
        var sawHistoryDone = false
        for i in 0..<min(count, paths.count) {
            let f = Int(flags[i])
            lastID = max(lastID, ids[i])
            if f & kFSEventStreamEventFlagHistoryDone != 0 {
                sawHistoryDone = true
                continue
            }
            let recursive = f & (kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged) != 0
            var path = paths[i]
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            changes.append(FileIndexChange(path: path, recursive: recursive))
        }
        if !changes.isEmpty { handler(changes, lastID) }
        if sawHistoryDone { signalHistoryDone() }
    }
}
