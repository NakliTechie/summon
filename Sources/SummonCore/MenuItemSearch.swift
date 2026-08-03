import Foundation

/// Menu-item search (M1). Fake enumerator for tests; live AX later.
public struct MenuItemDescriptor: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let path: String
    public let appBundleID: String

    public init(id: String, title: String, path: String, appBundleID: String) {
        self.id = id
        self.title = title
        self.path = path
        self.appBundleID = appBundleID
    }
}

public protocol MenuItemEnumerating: Sendable {
    func enumerate() throws -> [MenuItemDescriptor]
}

public struct FakeMenuItemEnumerator: MenuItemEnumerating, Sendable {
    public var items: [MenuItemDescriptor]
    public init(items: [MenuItemDescriptor] = [
        MenuItemDescriptor(id: "file.new", title: "New", path: "File > New", appBundleID: "com.apple.dt.Xcode"),
        MenuItemDescriptor(id: "edit.paste", title: "Paste", path: "Edit > Paste", appBundleID: "com.apple.TextEdit"),
    ]) {
        self.items = items
    }
    public func enumerate() throws -> [MenuItemDescriptor] { items }
}

public struct MenuItemSearch: Sendable {
    public var enumerator: any MenuItemEnumerating
    public init(enumerator: any MenuItemEnumerating = FakeMenuItemEnumerator()) {
        self.enumerator = enumerator
    }

    public func search(query: String, limit: Int = 30) throws -> [SearchResult] {
        let q = query.lowercased()
        let hits = try enumerator.enumerate().filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }.prefix(limit)
        return hits.enumerated().map { i, m in
            SearchResult(
                id: "menu:\(m.id)",
                title: m.title,
                subtitle: m.path,
                kind: .command,
                score: Double(740 - i),
                payload: [
                    "menuPath": .string(m.path),
                    "bundleID": .string(m.appBundleID),
                ]
            )
        }
    }
}
