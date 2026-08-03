import Foundation

/// Object→action grammar (LaunchBar/Raycast Tab-on-result): actions available for a selected object.
public struct ObjectAction: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Machine name for CLI (`app.open`, `file.reveal`, …).
    public let name: String
    public let isDestructive: Bool

    public init(id: String, title: String, name: String, isDestructive: Bool = false) {
        self.id = id
        self.title = title
        self.name = name
        self.isDestructive = isDestructive
    }
}

public enum ObjectActionGrammar {
    /// Actions available for a result kind. Deterministic; modules append later.
    public static func actions(for result: SearchResult) -> [ObjectAction] {
        switch result.kind {
        case .app:
            return [
                ObjectAction(id: "open", title: "Open", name: "app.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "app.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
            ]
        case .file:
            return [
                ObjectAction(id: "open", title: "Open", name: "file.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "file.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
            ]
        case .folder:
            return [
                ObjectAction(id: "open", title: "Open", name: "file.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "file.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
            ]
        case .snippet:
            return [
                ObjectAction(id: "paste", title: "Paste", name: "snippet.paste"),
                ObjectAction(id: "copy", title: "Copy", name: "snippet.copy"),
                ObjectAction(id: "edit", title: "Edit", name: "snippet.edit"),
                ObjectAction(id: "delete", title: "Delete", name: "snippet.delete", isDestructive: true),
            ]
        case .calculation:
            return [
                ObjectAction(id: "copy", title: "Copy Result", name: "calc.copy"),
                ObjectAction(id: "paste", title: "Paste Result", name: "calc.paste"),
            ]
        case .setting:
            return [
                ObjectAction(id: "open", title: "Open Setting", name: "settings.open"),
            ]
        case .command:
            return [
                ObjectAction(id: "run", title: "Run", name: "command.run"),
            ]
        }
    }
}
