import Foundation

/// Built-in dev utils (RC-51): UUID, base64, timestamp.
/// Only surfaces when the query is an explicit intent — never on empty query.
public enum DevUtils {
    public static func search(query freeText: String) -> [SearchResult] {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }

        var out: [SearchResult] = []
        if q == "uuid" || q == "guid" {
            let u = UUID().uuidString
            out.append(SearchResult(
                id: "dev:uuid",
                title: u,
                subtitle: "UUID",
                kind: .command,
                score: 0.9,
                payload: [
                    "copy": .string(u),
                    "dev": .string("uuid"),
                    "action": .string("snippet.copy"),
                    "text": .string(u),
                ]
            ))
        }
        if q.hasPrefix("base64 ") {
            let rest = payload(afterCommandIn: trimmed)
            if let data = rest.data(using: .utf8) {
                let enc = data.base64EncodedString()
                out.append(SearchResult(
                    id: "dev:b64enc",
                    title: enc,
                    subtitle: "base64 encode",
                    kind: .command,
                    score: 0.95,
                    payload: [
                        "copy": .string(enc),
                        "action": .string("snippet.copy"),
                        "text": .string(enc),
                    ]
                ))
            }
        }
        if q.hasPrefix("decode ") || q.hasPrefix("base64d ") {
            let rest = payload(afterCommandIn: trimmed)
            if let data = Data(base64Encoded: rest.trimmingCharacters(in: .whitespaces)),
               let s = String(data: data, encoding: .utf8) {
                out.append(SearchResult(
                    id: "dev:b64dec",
                    title: s,
                    subtitle: "base64 decode",
                    kind: .command,
                    score: 0.95,
                    payload: [
                        "copy": .string(s),
                        "action": .string("snippet.copy"),
                        "text": .string(s),
                    ]
                ))
            }
        }
        if q == "timestamp" || q == "now" || q == "ts" || q == "unix" {
            let ts = Int(Date().timeIntervalSince1970)
            out.append(SearchResult(
                id: "dev:ts",
                title: "\(ts)",
                subtitle: "unix timestamp",
                kind: .command,
                score: 0.85,
                payload: [
                    "copy": .string("\(ts)"),
                    "action": .string("snippet.copy"),
                    "text": .string("\(ts)"),
                ]
            ))
        }
        return out
    }

    private static func payload(afterCommandIn query: String) -> String {
        guard let separator = query.firstIndex(where: { $0.isWhitespace }) else { return "" }
        return String(query[separator...]).trimmingCharacters(in: .whitespaces)
    }
}
