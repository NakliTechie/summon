import Foundation

/// Calendar questions answered on the Mac, exactly, as a calculator row: "what day is 20th nov",
/// "what day of the week is 1 jan 2027", "how many days until 25 dec". These must not go to a
/// model or the web: on 2026-11-15 Apple FM said 20 November 2026 is a Saturday (it is a Friday)
/// and the web route returned Wikipedia pages about other days.
public enum DateAnswer {
    private enum Question { case weekday, daysUntil, daysSince }

    /// A calculator row for a calendar question, or nil when the query is not one.
    public static func result(for query: String, now: Date = Date(), calendar: Calendar = .current) -> SearchResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (question, rest) = parse(trimmed),
              let date = detectDate(in: rest, now: now, calendar: calendar) else { return nil }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let full = format(day, calendar: calendar)
        let title: String
        switch question {
        case .weekday:
            title = full
        case .daysUntil, .daysSince:
            title = "\(abs(offset)) \(abs(offset) == 1 ? "day" : "days") \(offset >= 0 ? "until" : "since") \(full)"
        }
        return SearchResult(
            id: "date:\(Int(day.timeIntervalSince1970))",
            title: title,
            subtitle: relative(offset) + " · computed on this Mac",
            kind: .calculation,
            score: 10_000,
            payload: ["value": .string(title)]
        )
    }

    /// "Friday, 20 November 2026" in the user's locale.
    static func format(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        return formatter.string(from: date)
    }

    static func relative(_ offset: Int) -> String {
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let days where days > 1: return "in \(days) days"
        default: return "\(-offset) days ago"
        }
    }

    /// The question and the text that should hold the date.
    private static func parse(_ query: String) -> (Question, String)? {
        let lower = query.lowercased()
        let patterns: [(String, Question)] = [
            (#"^(?:what|which)\s+day(?:\s+of\s+the\s+week)?\s+(?:is|was|will\s+be|falls\s+on)\s+(.+)$"#, .weekday),
            (#"^(?:what|which)\s+weekday\s+(?:is|was|will\s+be)\s+(.+)$"#, .weekday),
            (#"^(.+?)\s+is\s+(?:what|which)\s+day\??$"#, .weekday),
            (#"^(?:day\s+of\s+(?:the\s+)?week\s+(?:for|of)|weekday\s+(?:for|of))\s+(.+)$"#, .weekday),
            (#"^(?:how\s+many\s+)?days\s+(?:until|till|til|to|before)\s+(.+)$"#, .daysUntil),
            (#"^(?:how\s+many\s+)?days\s+(?:since|from|after)\s+(.+)$"#, .daysSince),
        ]
        for (pattern, question) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let range = Range(match.range(at: 1), in: lower) else { continue }
            let rest = String(lower[range]).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
            if !rest.isEmpty { return (question, rest) }
        }
        return nil
    }

    /// The date named in `text`. A date with no year is the next one on or after today
    /// ("25 dec" in November is this year's; "1 jan" is next year's).
    private static func detectDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        switch text {
        case "today": return now
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: now)
        default: break
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date else { return nil }
        // The detected span must be most of the text, so "what day is my dentist" stays unanswered.
        guard Double(match.range.length) >= Double((text as NSString).length) * 0.6 else { return nil }
        let statesYear = text.range(of: #"\b(19|20)\d{2}\b|'\d{2}\b"#, options: .regularExpression) != nil
        guard !statesYear else { return date }
        var parts = calendar.dateComponents([.month, .day], from: date)
        parts.year = calendar.component(.year, from: now)
        guard let thisYear = calendar.date(from: parts) else { return date }
        if calendar.startOfDay(for: thisYear) >= calendar.startOfDay(for: now) { return thisYear }
        parts.year = (parts.year ?? 0) + 1
        return calendar.date(from: parts) ?? thisYear
    }
}
