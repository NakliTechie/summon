import Foundation

/// Returns the operation's result, or throws when `seconds` pass first. The caller
/// stops waiting at the deadline even if the operation ignores cancellation (an
/// on-device model call stuck behind a busy system), which a task group cannot do:
/// it would wait for every child to finish before returning.
func withDeadline<T: Sendable>(
    seconds: Double,
    timeout: @autoclosure @escaping @Sendable () -> Error,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OnceGate()
        let work = Task {
            do {
                let value = try await operation()
                if gate.take() { continuation.resume(returning: value) }
            } catch {
                if gate.take() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.take() {
                work.cancel()
                continuation.resume(throwing: timeout())
            }
        }
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
