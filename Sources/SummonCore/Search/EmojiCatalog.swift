import Foundation

/// Small built-in emoji index for M1 (expand later). No network.
public struct EmojiCatalog: Sendable {
    public struct Entry: Sendable, Hashable {
        public let glyph: String
        public let name: String
        public let keywords: [String]
    }

    public let entries: [Entry]

    public init(entries: [Entry]? = nil) {
        self.entries = entries ?? Self.seed
    }

    public func search(query: FilterQuery, limit: Int = 30) -> [SearchResult] {
        if let kind = query.kind, kind != "emoji" { return [] }
        let free = query.freeText.lowercased()
        let hits: [Entry]
        if free.isEmpty {
            hits = Array(entries.prefix(limit))
        } else {
            hits = entries.filter {
                $0.name.lowercased().contains(free)
                    || $0.keywords.contains { $0.lowercased().contains(free) }
                    || $0.glyph == free
            }.prefix(limit).map { $0 }
        }
        return hits.enumerated().map { index, e in
            SearchResult(
                id: "emoji:\(e.glyph)",
                title: "\(e.glyph)  \(e.name)",
                subtitle: e.keywords.joined(separator: ", "),
                kind: .emoji,
                score: Double(750 - index),
                payload: [
                    "text": .string(e.glyph),
                    "emoji": .string(e.glyph),
                ]
            )
        }
    }

    private static let seed: [Entry] = [
        Entry(glyph: "✅", name: "check mark", keywords: ["ok", "done", "yes"]),
        Entry(glyph: "❌", name: "cross mark", keywords: ["no", "x", "cancel"]),
        Entry(glyph: "⚠️", name: "warning", keywords: ["alert", "caution"]),
        Entry(glyph: "🔥", name: "fire", keywords: ["hot", "lit"]),
        Entry(glyph: "💡", name: "light bulb", keywords: ["idea"]),
        Entry(glyph: "🚀", name: "rocket", keywords: ["ship", "launch"]),
        Entry(glyph: "📎", name: "paperclip", keywords: ["attach"]),
        Entry(glyph: "🔍", name: "magnifying glass", keywords: ["search", "find"]),
        Entry(glyph: "📋", name: "clipboard", keywords: ["paste", "copy"]),
        Entry(glyph: "⭐️", name: "star", keywords: ["favorite", "fav"]),
        Entry(glyph: "❤️", name: "red heart", keywords: ["love", "like"]),
        Entry(glyph: "👍", name: "thumbs up", keywords: ["yes", "approve"]),
        Entry(glyph: "🎉", name: "party popper", keywords: ["celebrate", "tada"]),
        Entry(glyph: "🐛", name: "bug", keywords: ["debug", "issue"]),
        Entry(glyph: "⚡️", name: "high voltage", keywords: ["fast", "zap"]),
        Entry(glyph: "😀", name: "grinning face", keywords: ["smile", "happy"]),
        Entry(glyph: "😅", name: "grinning sweat", keywords: ["relief", "nervous"]),
        Entry(glyph: "😂", name: "joy", keywords: ["laugh", "lol"]),
        Entry(glyph: "🥹", name: "holding back tears", keywords: ["emotional"]),
        Entry(glyph: "😊", name: "smiling eyes", keywords: ["blush"]),
        Entry(glyph: "😍", name: "heart eyes", keywords: ["love"]),
        Entry(glyph: "🤔", name: "thinking", keywords: ["hmm", "consider"]),
        Entry(glyph: "😴", name: "sleeping", keywords: ["tired", "zzz"]),
        Entry(glyph: "🙌", name: "raising hands", keywords: ["praise", "hooray"]),
        Entry(glyph: "👏", name: "clapping", keywords: ["bravo"]),
        Entry(glyph: "💪", name: "flexed biceps", keywords: ["strong"]),
        Entry(glyph: "👀", name: "eyes", keywords: ["look", "see"]),
        Entry(glyph: "🧠", name: "brain", keywords: ["smart", "think"]),
        Entry(glyph: "💻", name: "laptop", keywords: ["computer", "code"]),
        Entry(glyph: "📱", name: "mobile phone", keywords: ["phone"]),
        Entry(glyph: "⌨️", name: "keyboard", keywords: ["type"]),
        Entry(glyph: "🗂️", name: "card index dividers", keywords: ["files", "organize"]),
        Entry(glyph: "📂", name: "open file folder", keywords: ["folder"]),
        Entry(glyph: "🔗", name: "link", keywords: ["url", "href"]),
        Entry(glyph: "🔒", name: "locked", keywords: ["secure", "private"]),
        Entry(glyph: "🔓", name: "unlocked", keywords: ["open"]),
        Entry(glyph: "🔑", name: "key", keywords: ["password"]),
        Entry(glyph: "📝", name: "memo", keywords: ["note", "write"]),
        Entry(glyph: "📅", name: "calendar", keywords: ["date", "event"]),
        Entry(glyph: "⏰", name: "alarm clock", keywords: ["time", "reminder"]),
        Entry(glyph: "🌐", name: "globe", keywords: ["web", "world"]),
        Entry(glyph: "🧩", name: "puzzle piece", keywords: ["plugin", "extension"]),
        Entry(glyph: "🛠️", name: "hammer and wrench", keywords: ["tools", "build"]),
        Entry(glyph: "🧪", name: "test tube", keywords: ["test", "science"]),
        Entry(glyph: "📦", name: "package", keywords: ["box", "ship"]),
        Entry(glyph: "🎯", name: "direct hit", keywords: ["target", "goal"]),
        Entry(glyph: "✨", name: "sparkles", keywords: ["magic", "new"]),
        Entry(glyph: "🌈", name: "rainbow", keywords: ["pride", "color"]),
        Entry(glyph: "☕️", name: "hot beverage", keywords: ["coffee", "tea"]),
        Entry(glyph: "🍕", name: "pizza", keywords: ["food"]),
        Entry(glyph: "🌙", name: "crescent moon", keywords: ["night", "dark"]),
        Entry(glyph: "☀️", name: "sun", keywords: ["day", "light"]),
        Entry(glyph: "❄️", name: "snowflake", keywords: ["cold", "winter"]),
        Entry(glyph: "🎵", name: "musical note", keywords: ["music", "song"]),
        Entry(glyph: "🔔", name: "bell", keywords: ["notify", "alert"]),
        Entry(glyph: "🚫", name: "prohibited", keywords: ["block", "stop"]),
        Entry(glyph: "♻️", name: "recycling", keywords: ["recycle", "green"]),
        Entry(glyph: "⬇️", name: "down arrow", keywords: ["download"]),
        Entry(glyph: "⬆️", name: "up arrow", keywords: ["upload"]),
        Entry(glyph: "➡️", name: "right arrow", keywords: ["next"]),
        Entry(glyph: "⬅️", name: "left arrow", keywords: ["back"]),
        Entry(glyph: "➕", name: "plus", keywords: ["add", "new"]),
        Entry(glyph: "➖", name: "minus", keywords: ["remove"]),
        Entry(glyph: "🔁", name: "repeat", keywords: ["loop", "sync"]),
        Entry(glyph: "🏠", name: "house", keywords: ["home"]),
        Entry(glyph: "🏢", name: "office", keywords: ["work", "building"]),
        Entry(glyph: "👤", name: "bust in silhouette", keywords: ["user", "person"]),
        Entry(glyph: "👥", name: "busts", keywords: ["people", "team"]),
        Entry(glyph: "💬", name: "speech balloon", keywords: ["chat", "comment"]),
        Entry(glyph: "📣", name: "megaphone", keywords: ["announce"]),
        Entry(glyph: "🏷️", name: "label", keywords: ["tag"]),
        Entry(glyph: "📌", name: "pushpin", keywords: ["pin"]),
        Entry(glyph: "🗑️", name: "wastebasket", keywords: ["delete", "trash"]),
        Entry(glyph: "⏳", name: "hourglass", keywords: ["wait", "loading"]),
        Entry(glyph: "🤖", name: "robot", keywords: ["bot", "ai"]),
        Entry(glyph: "🪄", name: "magic wand", keywords: ["magic", "transform"]),
    ]
}
