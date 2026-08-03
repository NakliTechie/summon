import Foundation
import SummonCore

/// Native host tree node produced by the reconciler from extension render output.
/// Headless and UI-backed renderers both consume this shape.
public struct HostNode: Sendable, Hashable, Codable, Equatable {
    public let type: String
    public let props: [String: JSONValue]
    public let children: [HostNode]

    public init(type: String, props: [String: JSONValue] = [:], children: [HostNode] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    /// Canonical JSON for fixture equality (sorted keys).
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Depth-first search for the first node of a given type.
    public func first(ofType type: String) -> HostNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(ofType: type) { return found }
        }
        return nil
    }

    /// All nodes of a given type, depth-first.
    public func all(ofType type: String) -> [HostNode] {
        var out: [HostNode] = []
        if self.type == type { out.append(self) }
        for child in children {
            out.append(contentsOf: child.all(ofType: type))
        }
        return out
    }
}
