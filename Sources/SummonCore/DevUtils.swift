import Foundation

/// Built-in dev utils (RC-51): UUID, base64, timestamp.
public enum DevUtils {
    public static func search(query freeText: String) -> [SearchResult] {
        let q = freeText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [SearchResult] = []
        if q.isEmpty || "uuid".hasPrefix(q) || q == "uuid" {
            let u = UUID().uuidString
            out.append(SearchResult(
                id: "dev:uuid",
                title: u,
                subtitle: "UUID",
                kind: .command,
                score: 0.9,
                payload: ["copy": .string(u), "dev": .string("uuid")]
            ))
        }
        if q.hasPrefix("base64 ") {
            let rest = String(freeText.dropFirst(7))
            if let data = rest.data(using: .utf8) {
                let enc = data.base64EncodedString()
                out.append(SearchResult(
                    id: "dev:b64enc",
                    title: enc,
                    subtitle: "base64 encode",
                    kind: .command,
                    score: 0.95,
                    payload: ["copy": .string(enc)]
                ))
            }
        }
        if q.hasPrefix("decode ") || q.hasPrefix("base64d ") {
            let rest = q.hasPrefix("decode ") ? String(freeText.dropFirst(7)) : String(freeText.dropFirst(8))
            if let data = Data(base64Encoded: rest.trimmingCharacters(in: .whitespaces)),
               let s = String(data: data, encoding: .utf8) {
                out.append(SearchResult(
                    id: "dev:b64dec",
                    title: s,
                    subtitle: "base64 decode",
                    kind: .command,
                    score: 0.95,
                    payload: ["copy": .string(s)]
                ))
            }
        }
        if q.isEmpty || "timestamp".hasPrefix(q) || q == "now" || q == "ts" {
            let ts = Int(Date().timeIntervalSince1970)
            out.append(SearchResult(
                id: "dev:ts",
                title: "\(ts)",
                subtitle: "unix timestamp",
                kind: .command,
                score: 0.85,
                payload: ["copy": .string("\(ts)")]
            ))
        }
        return out
    }
}
