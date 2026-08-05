import Foundation

/// Parse hex colors (RC-52).
public enum ColorPickerUtil {
    public static func parse(_ raw: String) -> SearchResult? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        let r = Int(s.prefix(2), radix: 16) ?? 0
        let g = Int(s.dropFirst(2).prefix(2), radix: 16) ?? 0
        let b = Int(s.dropFirst(4).prefix(2), radix: 16) ?? 0
        let rgb = "rgb(\(r), \(g), \(b))"
        return SearchResult(
            id: "color:#\(s.lowercased())",
            title: "#\(s.uppercased())",
            subtitle: rgb,
            kind: .command,
            score: 0.92,
            payload: [
                "copy": .string("#\(s.uppercased())"),
                "rgb": .string(rgb),
                "text": .string("#\(s.uppercased())"),
                "action": .string("snippet.copy"),
            ]
        )
    }
}
