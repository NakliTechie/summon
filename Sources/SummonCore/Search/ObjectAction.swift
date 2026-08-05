import Foundation

/// Object→action grammar (LaunchBar/Raycast Tab-on-result).
public struct ObjectAction: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
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
    public static func actions(for result: SearchResult, isFavorite: Bool? = nil) -> [ObjectAction] {
        var actions: [ObjectAction]
        switch result.kind {
        case .app:
            actions = [
                ObjectAction(id: "open", title: "Open", name: "app.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "app.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
            ]
        case .file:
            actions = [
                ObjectAction(id: "open", title: "Open", name: "file.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "file.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
                ObjectAction(id: "trash", title: "Move to Trash", name: "file.trash", isDestructive: true),
                ObjectAction(id: "get-info", title: "Get Info", name: "file.getInfo"),
            ]
        case .folder:
            actions = [
                ObjectAction(id: "open", title: "Open", name: "file.open"),
                ObjectAction(id: "reveal", title: "Reveal in Finder", name: "file.reveal"),
                ObjectAction(id: "copy-path", title: "Copy Path", name: "file.copyPath"),
                ObjectAction(id: "trash", title: "Move to Trash", name: "file.trash", isDestructive: true),
            ]
        case .snippet:
            actions = [
                ObjectAction(id: "copy", title: "Copy", name: "snippet.copy"),
                ObjectAction(id: "delete", title: "Delete", name: "snippet.delete", isDestructive: true),
            ]
        case .calculation:
            actions = [
                ObjectAction(id: "copy", title: "Copy Result", name: "calc.copy"),
            ]
        case .setting:
            actions = [
                ObjectAction(id: "open", title: "Open Setting", name: "settings.open"),
            ]
        case .command:
            if result.payload["action"]?.stringValue == "ai.stage" {
                actions = [
                    ObjectAction(id: "stage", title: "Stage Proposal", name: "ai.stage"),
                ]
            } else {
                actions = [
                    ObjectAction(id: "run", title: "Run", name: "command.run"),
                ]
            }
        case .clipboard:
            let pinned = result.payload["pinned"]?.boolValue ?? false
            let isImage = result.payload["contentKind"]?.stringValue == ClipboardContentKind.image.rawValue
            actions = [
                ObjectAction(id: "copy", title: "Copy", name: "clipboard.copy"),
            ]
            if !isImage {
                actions.append(
                    ObjectAction(
                        id: "copy-plain",
                        title: "Copy as Plain Text",
                        name: "clipboard.copyPlain"
                    )
                )
            }
            actions.append(
                ObjectAction(
                    id: pinned ? "unpin" : "pin",
                    title: pinned ? "Unpin" : "Pin",
                    name: pinned ? "clipboard.unpin" : "clipboard.pin"
                )
            )
            actions.append(
                ObjectAction(id: "delete", title: "Delete", name: "clipboard.delete", isDestructive: true)
            )
        case .quicklink:
            actions = [
                ObjectAction(id: "open", title: "Open", name: "quicklink.open"),
                ObjectAction(id: "copy", title: "Copy URL", name: "file.copyPath"),
                ObjectAction(id: "delete", title: "Delete", name: "quicklink.delete", isDestructive: true),
            ]
        case .emoji:
            actions = [
                ObjectAction(id: "copy", title: "Copy emoji", name: "emoji.copy"),
            ]
        }
        if let isFavorite, [.app, .file, .folder, .quicklink].contains(result.kind) {
            actions.append(ObjectAction(
                id: isFavorite ? "unfavorite" : "favorite",
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                name: isFavorite ? "favorite.remove" : "favorite.add",
                isDestructive: isFavorite
            ))
        }
        return actions
    }
}
