import Foundation

/// The grounding guard for model-written fills: a value is kept only when the
/// copied text states it. A language model asked to copy values sometimes writes
/// a plausible one the text never had (the 2026-10-31 experiment: Apple FM made
/// up a talk title, a talk length and a handle for a speaker form). The guard
/// fails closed, so a dropped real value costs one empty field, never a wrong one.
///
/// Matching tolerates formatting, not content:
/// - text: case, accents, punctuation and spacing ("ANANYA  Iyer" ~ "Ananya Iyer");
/// - lists: every comma- or semicolon-separated part is stated ("Swift; Core Data");
/// - URLs: scheme, "www." and a trailing slash;
/// - numbers: separators, and an added or dropped country code on 7+ digits;
/// - dates: format, when year, month and any day agree ("2021-03" ~ "March 2021").
public enum SmartPasteGrounding {
    public static func isGrounded(_ value: String, in source: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let text = normalized(source)
        if stated(trimmed, in: text) { return true }
        if isNumeric(trimmed), numberStated(trimmed, in: source) { return true }
        let valueDates = dateKeys(in: trimmed, wholeValue: true)
        if !valueDates.isEmpty, !valueDates.isDisjoint(with: dateKeys(in: source, wholeValue: false)) { return true }
        let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1, parts.allSatisfy({ !$0.isEmpty && stated($0, in: text) }) { return true }
        return false
    }

    // MARK: Text and URLs

    private static func stated(_ value: String, in normalizedSource: String) -> Bool {
        let source = " " + normalizedSource + " "
        for candidate in [value, urlKey(value)] {
            let needle = normalized(candidate)
            if !needle.isEmpty, source.contains(" " + needle + " ") { return true }
        }
        return false
    }

    /// Lowercased, accent-folded, every run of non-alphanumerics one space.
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func urlKey(_ text: String) -> String {
        var key = text.lowercased()
        for prefix in ["https://", "http://", "www."] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    // MARK: Numbers

    /// No letters and at least one digit: a phone, amount, postcode or count.
    private static func isNumeric(_ value: String) -> Bool {
        !value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
    }

    private static func numberStated(_ value: String, in source: String) -> Bool {
        let digits = value.filter(\.isASCIIDigit)
        guard !digits.isEmpty else { return false }
        let groups = source.split(whereSeparator: { !$0.isASCIIDigit }).map(String.init)
        if groups.contains(digits) { return true }
        for span in matches(of: #"\d[\d \t().,\-–/]*\d"#, in: source) {
            let spanDigits = span.filter(\.isASCIIDigit)
            if spanDigits == digits { return true }
            let (short, long) = spanDigits.count < digits.count ? (spanDigits, digits) : (digits, spanDigits)
            if short.count >= 7, long.hasSuffix(short) { return true }
        }
        return false
    }

    // MARK: Dates

    struct DateKey: Hashable {
        let year: Int
        let month: Int
        let day: Int?
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthWord = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#

    /// Year-month(-day) keys for each date written in `text`. A numeric day/month
    /// pair is ambiguous, so it yields both orders. With `wholeValue`, the pattern
    /// must span the whole (trimmed) value, so a fill is matched only as a date.
    static func dateKeys(in text: String, wholeValue: Bool) -> Set<DateKey> {
        let lower = text.lowercased()
        let wrap: (String) -> String = { wholeValue ? "^\\s*" + $0 + "\\s*$" : "(?<![0-9a-z])" + $0 + "(?![0-9a-z])" }
        var keys: Set<DateKey> = []
        let add = { (year: Int, month: Int, day: Int?) in
            guard (1...12).contains(month), (1900...2199).contains(year) else { return }
            if let day, !(1...31).contains(day) { return }
            keys.insert(DateKey(year: year, month: month, day: day))
        }
        for g in captures(of: wrap(#"(\d{4})-(\d{1,2})(?:-(\d{1,2}))?"#), in: lower) {
            add(Int(g[0]) ?? 0, Int(g[1]) ?? 0, Int(g[2]))
        }
        for g in captures(of: wrap(#"(\d{1,2})[/.](\d{1,2})[/.](\d{4})"#), in: lower) {
            let first = Int(g[0]) ?? 0, second = Int(g[1]) ?? 0, year = Int(g[2]) ?? 0
            add(year, second, first)
            add(year, first, second)
        }
        for g in captures(of: wrap(#"(\d{1,2})[/.](\d{4})"#), in: lower) {
            add(Int(g[1]) ?? 0, Int(g[0]) ?? 0, nil)
        }
        for g in captures(of: wrap(monthWord + #"\s+(?:(\d{1,2})(?:st|nd|rd|th)?,?\s+)?(\d{4})"#), in: lower) {
            add(Int(g[2]) ?? 0, monthIndex(g[0]), Int(g[1]))
        }
        for g in captures(of: wrap(#"(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthWord + #",?\s+(\d{4})"#), in: lower) {
            add(Int(g[2]) ?? 0, monthIndex(g[1]), Int(g[0]))
        }
        return keys
    }

    private static func monthIndex(_ word: String) -> Int {
        (months.firstIndex { word.hasPrefix($0) } ?? -1) + 1
    }

    // MARK: Regex plumbing

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Capture groups per match; an unmatched optional group is "".
    private static func captures(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
