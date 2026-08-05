import Darwin
import Foundation

struct BoundedProcessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
}

enum BoundedProcessError: Error, LocalizedError, Equatable {
    case untrustedExecutable(String)
    case spawnFailed(String)
    case timedOut(seconds: TimeInterval, stderr: String)

    var errorDescription: String? {
        switch self {
        case .untrustedExecutable(let path):
            return "process executable is not an executable absolute path: \(path)"
        case .spawnFailed(let reason):
            return "process spawn failed: \(reason)"
        case .timedOut(let seconds, let stderr):
            let suffix = stderr.isEmpty ? "" : ": \(stderr)"
            return "process timed out after \(String(format: "%.1f", seconds)) seconds\(suffix)"
        }
    }
}

private final class BoundedProcessBuffer: @unchecked Sendable {
    private let limit: Int
    private var bytes = Data()
    private var didTruncate = false
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
            didTruncate = true
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, didTruncate)
    }
}

enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int = 2 * 1_024 * 1_024,
        maximumStandardErrorBytes: Int = 256 * 1_024
    ) throws -> BoundedProcessResult {
        let path = executableURL.path
        guard executableURL.isFileURL,
              path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw BoundedProcessError.untrustedExecutable(path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = BoundedProcessBuffer(limit: maximumStandardOutputBytes)
        let error = BoundedProcessBuffer(limit: maximumStandardErrorBytes)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            error.append(handle.availableData)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw BoundedProcessError.spawnFailed(error.localizedDescription)
        }

        let waitResult = finished.wait(timeout: .now() + max(0.1, timeout))
        if waitResult == .timedOut {
            let descendants = descendantPIDs(of: process.processIdentifier)
            for pid in descendants.reversed() {
                Darwin.kill(pid, SIGTERM)
            }
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            for pid in descendants.reversed() {
                Darwin.kill(pid, SIGKILL)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        error.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        let outputSnapshot = output.snapshot()
        let errorSnapshot = error.snapshot()
        if waitResult == .timedOut {
            let stderr = (String(data: errorSnapshot.data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BoundedProcessError.timedOut(seconds: timeout, stderr: String(stderr.prefix(400)))
        }

        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputSnapshot.data,
            standardError: errorSnapshot.data,
            standardOutputTruncated: outputSnapshot.truncated,
            standardErrorTruncated: errorSnapshot.truncated
        )
    }

    private static func descendantPIDs(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        var visited = Set([root])
        while let parent = queue.first {
            queue.removeFirst()
            for child in directChildPIDs(of: parent) where visited.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func directChildPIDs(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 1_024)
        let returnedCount = pids.withUnsafeMutableBytes { bytes in
            proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
        }
        guard returnedCount > 0 else { return [] }
        let count = min(Int(returnedCount), pids.count)
        return pids.prefix(count).filter { $0 > 0 }
    }
}
