import Foundation
import SummonCore

/// Deterministic natural-language → typed `CoreAction` for the classified action
/// intents. The harness owns the action decision — it never depends on the
/// on-device model calling a tool (which the small model does unreliably). If a
/// query can't be parsed into a concrete action, this returns nil and the query
/// falls through to the answer/search path.
public enum SummonActionParser {
    public static func parse(_ query: String) -> CoreAction? {
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
        return nil
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
