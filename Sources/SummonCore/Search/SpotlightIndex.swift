import Darwin
import Foundation

private final class BoundedSpotlightBuffer: @unchecked Sendable {
    private let limit: Int
    private var bytes = Data()
    private var truncated = false
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        if remaining > 0 {
            bytes.append(incoming.prefix(remaining))
        }
        if incoming.count > remaining {
            truncated = true
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, truncated)
    }
}

struct BoundedSpotlightCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let didTimeOut: Bool
    let standardOutput: Data
    let standardOutputTruncated: Bool
}

/// S1 search provider seam. Production uses `mdfind`; tests inject fixtures.
public protocol SpotlightIndexing: Sendable {
    func search(query: FilterQuery, limit: Int) throws -> [SearchResult]
}

/// In-memory / fixture Spotlight for headless tests (no real mdfind).
public struct FakeSpotlightIndex: SpotlightIndexing, Sendable {
    public var files: [SearchResult]

    public init(files: [SearchResult] = []) {
        self.files = files
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        var results = files
        if let kind = query.kind {
            results = results.filter { result in
                switch kind {
                case "pdf":
                    return result.path?.lowercased().hasSuffix(".pdf") == true
                case "folder":
                    return result.kind == .folder
                case "image":
                    let ext = (result.path as NSString?)?.pathExtension.lowercased() ?? ""
                    return ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
                case "app":
                    return result.kind == .app
                case "file":
                    return result.kind == .file
                default:
                    return true
                }
            }
        }
        if let path = query.pathPrefix {
            results = results.filter { ($0.path ?? "").hasPrefix(path) }
        }
        if let name = query.nameContains?.lowercased() {
            results = results.filter { $0.title.lowercased().contains(name) }
        }
        let free = query.freeText.lowercased()
        if !free.isEmpty {
            results = results.filter {
                $0.title.lowercased().contains(free)
                    || ($0.subtitle?.lowercased().contains(free) ?? false)
                    || ($0.path?.lowercased().contains(free) ?? false)
            }
        }
        if let bound = query.modified {
            let now = Date()
            results = results.filter { result in
                guard case .number(let epoch) = result.payload["mtime"] else { return true }
                let date = Date(timeIntervalSince1970: epoch)
                return bound.matches(date: date, now: now)
            }
        }
        return Array(results.prefix(limit))
    }
}

/// Real S1: shells out to `mdfind` with a constructed Spotlight query.
/// Headless-safe: fails soft (empty) if mdfind is unavailable.
///
/// Single-character `*c*` predicates scan the whole volume and block the UI for
/// tens of seconds — skip short free-text and hard-timeout the process.
public struct MdfindSpotlightIndex: SpotlightIndexing, Sendable {
    /// Minimum free-text / name length before invoking mdfind (apps still search at 1 char).
    /// 3 chars avoids broad `*ab*` scans that dominate keystroke latency.
    public static let minimumQueryLength = 3
    /// Wall-clock budget for mdfind; over → terminate and return empty.
    public static let processTimeoutSeconds: TimeInterval = 0.2
    static let maximumResultCount = 500
    static let maximumRetainedOutputBytes = 2 * 1_024 * 1_024

    public init() {}

    /// Strip MDQuery metacharacters that break predicates (`"`, `\`, `*`).
    public static func escapeMDQuery(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        let resultLimit = min(max(0, limit), Self.maximumResultCount)
        guard resultLimit > 0 else { return [] }
        guard let predicate = Self.queryPredicate(for: query) else { return [] }

        var args = [predicate]
        if let path = query.pathPrefix {
            args = ["-onlyin", path, predicate]
        }
        let commandResult: BoundedSpotlightCommandResult
        do {
            commandResult = try Self.runBoundedCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
                arguments: args,
                timeout: Self.processTimeoutSeconds,
                maximumOutputBytes: Self.outputBudget(for: resultLimit)
            )
        } catch {
            return []
        }
        guard commandResult.terminationStatus == 0 || commandResult.didTimeOut else { return [] }
        let paths = Self.paths(
            from: commandResult.standardOutput,
            truncated: commandResult.standardOutputTruncated || commandResult.didTimeOut
        )
        return Self.results(paths: paths, query: query, limit: resultLimit)
    }

    static func queryPredicate(for query: FilterQuery) -> String? {
        var parts: [String] = []
        let free = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Broad name wildcards on 0–1 chars hang mdfind on a full disk.
        if free.count >= Self.minimumQueryLength {
            let escaped = Self.escapeMDQuery(free)
            parts.append("kMDItemDisplayName == \"*\(escaped)*\"cd")
        }
        if let kind = query.kind {
            switch kind {
            case "pdf":
                parts.append("kMDItemContentTypeTree == 'com.adobe.pdf'")
            case "folder":
                parts.append("kMDItemContentTypeTree == 'public.folder'")
            case "image":
                parts.append("kMDItemContentTypeTree == 'public.image'")
            case "app":
                parts.append("kMDItemContentTypeTree == 'com.apple.application-bundle'")
            default:
                break
            }
        }
        var hasValidNameFragment = false
        if let name = query.nameContains {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= Self.minimumQueryLength {
                let escaped = Self.escapeMDQuery(trimmed)
                parts.append("kMDItemDisplayName == \"*\(escaped)*\"cd")
                hasValidNameFragment = true
            }
        }

        if parts.isEmpty {
            return nil
        } else if parts.count == 1 {
            // Kind-only with no name still scans too much — require a name fragment.
            if free.count < Self.minimumQueryLength, !hasValidNameFragment {
                return nil
            }
            return parts[0]
        } else {
            return parts.map { "(\($0))" }.joined(separator: " && ")
        }
    }

    static func outputBudget(for resultLimit: Int) -> Int {
        min(max(64 * 1_024, max(0, resultLimit) * 4_096), maximumRetainedOutputBytes)
    }

    static func paths(from data: Data, truncated: Bool) -> [String] {
        var completeData = data
        if truncated, completeData.last != 0x0A {
            guard let lastNewline = completeData.lastIndex(of: 0x0A) else { return [] }
            completeData = completeData.prefix(through: lastNewline)
        }
        guard let text = String(data: completeData, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Drains both pipes while the process runs. Output beyond the retention
    /// budget is discarded after reading so a broad query cannot block on a
    /// full pipe or grow memory without bound.
    static func runBoundedCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> BoundedSpotlightCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = BoundedSpotlightBuffer(limit: maximumOutputBytes)
        let error = BoundedSpotlightBuffer(limit: 8 * 1_024)

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw error
        }

        let drainers = DispatchGroup()
        drain(outputPipe.fileHandleForReading, into: output, group: drainers)
        drain(errorPipe.fileHandleForReading, into: error, group: drainers)

        let waitResult = finished.wait(timeout: .now() + max(0.01, timeout))
        let didTimeOut = waitResult == .timedOut
        if didTimeOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        if drainers.wait(timeout: .now() + 1) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = drainers.wait(timeout: .now() + 0.25)
        }

        let outputSnapshot = output.snapshot()
        return BoundedSpotlightCommandResult(
            terminationStatus: process.isRunning ? -1 : process.terminationStatus,
            didTimeOut: didTimeOut,
            standardOutput: outputSnapshot.data,
            standardOutputTruncated: outputSnapshot.truncated
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: BoundedSpotlightBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let data: Data
                do {
                    data = try handle.read(upToCount: 32 * 1_024) ?? Data()
                } catch {
                    return
                }
                guard !data.isEmpty else { return }
                buffer.append(data)
            }
        }
    }

    /// Applies filesystem-backed clauses that `mdfind` does not encode.
    /// Kept internal so deterministic tests can exercise the production post-filter.
    static func results(
        paths: [String],
        query: FilterQuery,
        limit: Int,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [SearchResult] {
        let matchingPaths = paths.filter { path in
            guard let bound = query.modified else { return true }
            guard let modified = try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
                return false
            }
            return bound.matches(date: modified, now: now)
        }

        return matchingPaths.prefix(limit).enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let kind: SearchResult.Kind = path.hasSuffix(".app") ? .app : (isDir ? .folder : .file)
            var payload: [String: JSONValue] = [:]
            if let modified = try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                payload["mtime"] = .number(modified.timeIntervalSince1970)
            }
            return SearchResult(
                id: "file:\(path)",
                title: url.lastPathComponent,
                subtitle: path,
                kind: kind,
                path: path,
                score: Double(500 - index),
                payload: payload
            )
        }
    }
}
