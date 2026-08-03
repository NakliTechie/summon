import Foundation

/// Deterministic system commands from the launcher (M1). No shell injection.
public struct SystemCommands: Sendable {
    public struct Command: Sendable, Hashable {
        public let id: String
        public let title: String
        public let keywords: [String]
        public let url: String
    }

    public let commands: [Command]

    public init(commands: [Command]? = nil) {
        self.commands = commands ?? Self.seed
    }

    public func search(query: FilterQuery, limit: Int = 30) -> [SearchResult] {
        if let kind = query.kind, kind != "command" && kind != "system" { return [] }
        let free = query.freeText.lowercased()
        let hits: [Command]
        if free.isEmpty {
            hits = Array(commands.prefix(limit))
        } else {
            hits = commands.filter {
                $0.title.lowercased().contains(free)
                    || $0.keywords.contains { $0.lowercased().contains(free) }
                    || $0.id.lowercased().contains(free)
            }.prefix(limit).map { $0 }
        }
        return hits.enumerated().map { index, c in
            SearchResult(
                id: "command:\(c.id)",
                title: c.title,
                subtitle: "System",
                kind: .command,
                path: c.url,
                score: Double(780 - index),
                payload: ["url": .string(c.url)]
            )
        }
    }

    private static let prefs = "x-apple.systempreferences:"

    private static let seed: [Command] = [
        Command(id: "sleep", title: "Sleep", keywords: ["suspend"], url: "summon://system/sleep"),
        Command(id: "lock", title: "Lock Screen", keywords: ["lock"], url: "summon://system/lock"),
        Command(
            id: "empty-trash",
            title: "Empty Trash",
            keywords: ["trash"],
            url: "summon://system/empty-trash"
        ),
        Command(
            id: "prefs",
            title: "System Settings",
            keywords: ["preferences", "settings"],
            url: prefs
        ),
        Command(
            id: "about",
            title: "About This Mac",
            keywords: ["about"],
            url: prefs + "com.apple.SystemProfiler.AboutExtension"
        ),
        Command(
            id: "displays",
            title: "Displays Settings",
            keywords: ["monitor", "screen"],
            url: prefs + "com.apple.Displays-Settings.extension"
        ),
        Command(
            id: "network",
            title: "Network Settings",
            keywords: ["wifi", "ethernet"],
            url: prefs + "com.apple.Network-Settings.extension"
        ),
        Command(
            id: "bluetooth",
            title: "Bluetooth Settings",
            keywords: ["bt"],
            url: prefs + "com.apple.BluetoothSettings"
        ),
        Command(
            id: "sound",
            title: "Sound Settings",
            keywords: ["audio", "volume"],
            url: prefs + "com.apple.Sound-Settings.extension"
        ),
        Command(
            id: "battery",
            title: "Battery Settings",
            keywords: ["power"],
            url: prefs + "com.apple.Battery-Settings.extension"
        ),
        Command(
            id: "privacy",
            title: "Privacy & Security",
            keywords: ["permissions"],
            url: prefs + "com.apple.preference.security"
        ),
        Command(
            id: "activity",
            title: "Activity Monitor",
            keywords: ["cpu", "memory"],
            url: "/System/Applications/Utilities/Activity Monitor.app"
        ),
        Command(
            id: "terminal",
            title: "Terminal",
            keywords: ["shell"],
            url: "/System/Applications/Utilities/Terminal.app"
        ),
        Command(
            id: "console",
            title: "Console",
            keywords: ["logs"],
            url: "/System/Applications/Utilities/Console.app"
        ),
    ]
}
