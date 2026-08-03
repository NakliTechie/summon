import Foundation

public enum CoreError: Error, Equatable, Sendable {
    case invalidActor(String)
    case schemaValidation(String)
    case unknownAction(String)
    case store(String)
    case journal(String)
    case io(String)

    public var message: String {
        switch self {
        case .invalidActor(let s): return "Invalid actor tag: \(s)"
        case .schemaValidation(let s): return "Schema validation failed: \(s)"
        case .unknownAction(let s): return "Unknown action: \(s)"
        case .store(let s): return "Store error: \(s)"
        case .journal(let s): return "Journal error: \(s)"
        case .io(let s): return "I/O error: \(s)"
        }
    }
}

extension CoreError: LocalizedError {
    public var errorDescription: String? { message }
}
