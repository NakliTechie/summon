import Foundation

/// Calendar questions answered on the Mac, exactly, as a calculator row: "what day is 20th nov",
/// "what day of the week is 1 jan 2027", "how many days until 25 dec". These must not go to a
/// model or the web: on 2026-11-15 Apple FM said 20 November 2026 is a Saturday (it is a Friday)
/// and the web route returned Wikipedia pages about other days.
public enum DateAnswer {
    private enum Question { case weekday, pastWeekday, daysUntil, daysSince }

    /// A calculator row for a calendar question, or nil when the query is not one.
    public static func result(for query: String, now: Date = Date(), calendar: Calendar = .current) -> SearchResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (question, rest) = parse(trimmed),
              let date = detectDate(in: rest, now: now, calendar: calendar,
                                    pastWhenYearless: question == .daysSince || question == .pastWeekday) else { return nil }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let full = format(day, calendar: calendar)
        let title: String
        switch question {
        case .weekday, .pastWeekday:
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
            (#"^(?:what|which)\s+day(?:\s+of\s+the\s+week)?\s+was\s+(.+)$"#, .pastWeekday),
            (#"^(?:what|which)\s+weekday\s+was\s+(.+)$"#, .pastWeekday),
            (#"^(?:what|which)\s+day(?:\s+of\s+the\s+week)?\s+(?:is|will\s+be|falls\s+on)\s+(.+)$"#, .weekday),
            (#"^(?:what|which)\s+weekday\s+(?:is|will\s+be)\s+(.+)$"#, .weekday),
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

    /// The date named in `text`. A date with no year is its next occurrence on or after today
    /// ("25 dec" in November is this year's, "1 jan" next year's), or its latest occurrence on or
    /// before today for "days since" and "what day was". "29 feb" goes to the nearest leap year.
    private static func detectDate(in text: String, now: Date, calendar: Calendar, pastWhenYearless: Bool) -> Date? {
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
        // NSDataDetector turns "29 feb" into 1 March in a non-leap year, so read that day from the text.
        let leapDay = #"\b29(?:st|nd|rd|th)?\s+(?:of\s+)?feb|\bfeb\w*\.?\s+29(?:st|nd|rd|th)?\b|\b29[/.\-]0?2\b|\b0?2[/.\-]29\b"#
        let wanted = text.range(of: leapDay, options: .regularExpression) != nil
            ? DateComponents(month: 2, day: 29)
            : calendar.dateComponents([.month, .day], from: date)
        // A stated four-digit year is used as written: NSDataDetector misreads some ("1 January 2100"
        // came back as 2027). A two-digit year ("04/01/30", "'30") is left to the detector.
        if let range = text.range(of: #"\b\d{4}\b"#, options: .regularExpression), let stated = Int(text[range]) {
            var parts = wanted
            parts.year = stated
            guard let exact = calendar.date(from: parts),
                  calendar.dateComponents([.month, .day], from: exact) == wanted else { return nil } // 29 Feb 2027
            return exact
        }
        guard text.range(of: #"'\d{2}\b|\b\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2}\b"#, options: .regularExpression) == nil else {
            // A two-digit year is left to the detector, but a day that year lacks gets no answer.
            return calendar.dateComponents([.month, .day], from: date) == wanted ? date : nil
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.component(.year, from: now)
        let step = pastWhenYearless ? -1 : 1
        for offset in 0..<9 {
            var parts = wanted
            parts.year = start + offset * step
            // A date that does not exist that year (29 February) rolls into March: skip it.
            guard let candidate = calendar.date(from: parts),
                  calendar.dateComponents([.month, .day], from: candidate) == wanted else { continue }
            let day = calendar.startOfDay(for: candidate)
            if pastWhenYearless ? day <= today : day >= today { return candidate }
        }
        return date
    }
}
