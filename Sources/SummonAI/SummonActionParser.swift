import Foundation
import SummonCore

/// Deterministic natural-language → typed `CoreAction` for the classified action
/// intents. The harness owns the action decision — it never depends on the
/// on-device model calling a tool (which the small model does unreliably). If a
/// query can't be parsed into a concrete action, this returns nil and the query
/// falls through to the answer/search path.
public enum SummonActionParser {
    public static func parse(_ rawQuery: String) -> CoreAction? {
        let query = SystemReaders.withoutPoliteLead(rawQuery)
        let intents = SystemReaders.mutatingIntents(for: query)
        if intents.contains(.setVolume), let level = volumeLevel(query) {
            let url = "summon://system/set-volume/\(level)"
            return .moduleRun(
                name: "command.run",
                targetID: "command:set-volume",
                path: url,
                payload: ["url": .string(url), "title": .string("Set volume to \(level)%")]
            )
        }
        if intents.contains(.createSnippet), let (name, body) = snippetFields(query) {
            return .snippetUpsert(id: UUID().uuidString, name: name, body: body, keyword: nil)
        }
        if intents.contains(.createQuicklink), let (name, url) = quicklinkFields(query) {
            return .quicklinkUpsert(id: UUID().uuidString, name: name, url: url, keyword: nil)
        }
        if intents.contains(.emptyTrash) { return systemEffect("empty-trash", title: "Empty Trash") }
        if intents.contains(.sleepMac) { return systemEffect("sleep", title: "Sleep") }
        if intents.contains(.lockScreen) { return systemEffect("lock", title: "Lock Screen") }
        if intents.contains(.sleepDisplay) { return systemEffect("sleep-display", title: "Display asleep.") }
        if intents.contains(.darkMode) { return systemEffect("dark-mode", title: "Appearance switched.") }
        if intents.contains(.sayText) {
            let text = query.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return .moduleRun(
                    name: "speech.speak", targetID: "speech", path: nil,
                    payload: ["text": .string(text), "title": .string("Said it.")]
                )
            }
        }
        if intents.contains(.takeScreenshot) {
            return .moduleRun(
                name: "screenshot.full", targetID: "shot:full", path: nil,
                payload: ["action": .string("screenshot.full"), "title": .string("Screenshot copied.")]
            )
        }
        return nil
    }

    /// A clean, honest decline for a clearly-unsupported action command — so Summon
    /// says it plainly rather than letting the small model improvise ("Sure, I'll
    /// remind you…"). Returns nil for questions and anything not obviously an
    /// unsupported action, so those still reach the answer/search path.
    public static func declineReason(_ query: String) -> String? {
        let q = SystemReaders.withoutPoliteLead(query).lowercased()
        guard !SystemReaders.isInformationQuestion(q) else { return nil }
        let messagingApp = q.contains("whatsapp") || q.contains("imessage")
        let sendsMessage = q.contains("email") || q.contains("e-mail")
            || q.hasPrefix("text ") || q.hasPrefix("dm ")
            || (q.contains("send") && (q.contains("message") || q.contains("text") || q.contains("dm")))
            || (q.contains("reply") && (q.contains("message") || q.contains("email") || q.contains("mail")))
            || messagingApp
        if sendsMessage { return "Summon can't access Mail or Messages yet." }
        let setsReminder = q.contains("remind me")
            || (q.contains("reminder") && (q.contains("add") || q.contains("set") || q.contains("create")))
        if setsReminder { return "Summon can't set reminders yet." }
        let addsEvent = q.contains("calendar") || q.hasPrefix("schedule ")
            || (q.contains("event") && (q.contains("add") || q.contains("create")))
        if addsEvent { return "Summon can't add calendar events yet." }
        let playsMedia = q.hasPrefix("play ")
            || ((q.contains("pause") || q.contains("skip")) && (q.contains("song") || q.contains("music") || q.contains("track")))
        if playsMedia { return "Summon can't control music yet." }
        let fileWords = q.contains(".") || q.contains("file") || q.contains("folder")
            || q.contains("draft") || q.contains("document")
        let mutatesFile = (q.hasPrefix("move ") || q.contains("rename ") || q.hasPrefix("trash ")) && fileWords
        if mutatesFile { return "Summon can't move, rename, or trash individual files yet." }
        if q.hasPrefix("quit ") || q.contains("force quit") { return "Summon can't quit apps yet." }
        return nil
    }

    /// A fixed system effect (empty-trash / sleep / lock) as a `command.run` module
    /// action. These are destructive/disruptive, so the harness stages them.
    private static func systemEffect(_ name: String, title: String) -> CoreAction {
        let url = "summon://system/\(name)"
        return .moduleRun(
            name: "command.run",
            targetID: "command:\(name)",
            path: url,
            payload: ["url": .string(url), "title": .string(title)]
        )
    }

    // MARK: - Field extraction

    static func volumeLevel(_ query: String) -> Int? {
        let lower = query.lowercased()
        if lower.contains("mute") || lower.contains("silence") { return 0 }
        if lower.contains("max") || lower.contains("full") { return 100 }
        var digits = ""
        for character in query {
            if character.isNumber {
                digits.append(character)
                if digits.count >= 3 { break }
            } else if !digits.isEmpty {
                break
            }
        }
        guard let value = Int(digits) else { return nil }
        return max(0, min(100, value))
    }

    private static let bodySeparators = [
        " that says ", " that reads ", " saying ", " with body ", " with text ", " = ",
    ]

    static func snippetFields(_ query: String) -> (name: String, body: String)? {
        for separator in bodySeparators {
            guard let range = query.range(of: separator, options: .caseInsensitive) else { continue }
            let body = trimmed(String(query[range.upperBound...]))
            guard !body.isEmpty else { continue }
            return (nameAfterKeyword(in: String(query[..<range.lowerBound])) ?? "Snippet", body)
        }
        return nil
    }

    static func quicklinkFields(_ query: String) -> (name: String, url: String)? {
        guard let url = firstURL(in: query) else { return nil }
        let name = nameAfterKeyword(in: query) ?? hostName(of: url)
        return (name, url)
    }

    private static func nameAfterKeyword(in text: String) -> String? {
        for keyword in ["called ", "named "] {
            guard let range = text.range(of: keyword, options: .caseInsensitive) else { continue }
            // Stop the name at " for " (quicklink URL clause) if present.
            var tail = String(text[range.upperBound...])
            if let forRange = tail.range(of: " for ", options: .caseInsensitive) {
                tail = String(tail[..<forRange.lowerBound])
            }
            let name = trimmed(tail)
            if !name.isEmpty { return name }
        }
        return nil
    }

    static func firstURL(in query: String) -> String? {
        for raw in query.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,()<>"))
            if token.contains("://") { return token }
            if token.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+(/.*)?$", options: .regularExpression)
                != nil, token.contains(".") {
                return "https://\(token)"
            }
        }
        return nil
    }

    private static func hostName(of url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Quicklink"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
