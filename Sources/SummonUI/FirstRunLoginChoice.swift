import Foundation

public enum FirstRunLoginChoice: Sendable, Equatable {
    case keepReady
    case notNow
    case decideLater

    public var requestedEnabled: Bool? {
        switch self {
        case .keepReady: return true
        case .notNow: return false
        case .decideLater: return nil
        }
    }

    public var marksPrompted: Bool {
        requestedEnabled != nil
    }
}
