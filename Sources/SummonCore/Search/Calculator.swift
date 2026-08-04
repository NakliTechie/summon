import Foundation

/// Inline calculator for the launcher bar (M1). Deterministic; no AI.
///
/// **Never** feed incomplete input to `NSExpression` — e.g. `"2 +"` raises an
/// uncaught `NSException` and aborts the process (crash 2026-08-04).
public enum Calculator {
    /// True when the query looks like a *complete* arithmetic expression.
    public static func looksLikeExpression(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/()%^ ")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasDigit = s.contains { $0.isNumber }
        guard hasDigit else { return false }
        // Incomplete while the user is still typing an operator.
        if let last = s.last, "+-*/%^.".contains(last) { return false }
        // Unbalanced parentheses → incomplete or invalid.
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        if depth != 0 { return false }
        // Pure number is ok; otherwise require an operator.
        let hasOp = s.contains { "+-*/%^".contains($0) }
        return hasOp || Double(s) != nil
    }

    /// Evaluate a simple arithmetic expression. Returns nil if not evaluable.
    public static func evaluate(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeExpression(s) else { return nil }
        if s.contains("^") {
            return evaluatePowerSimple(s)
        }
        // Prefer our parser — no ObjC exceptions on edge cases.
        if let v = evaluateParsed(s) {
            return v
        }
        return nil
    }

    public static func format(_ value: Double) -> String {
        if value.rounded() == value, let intValue = Int64(exactly: value) {
            return String(intValue)
        }
        return String(value)
    }

    public static func result(for query: String) -> SearchResult? {
        guard let value = evaluate(query) else { return nil }
        let formatted = format(value)
        return SearchResult(
            id: "calc:\(formatted)",
            title: formatted,
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .calculation,
            score: 10_000,
            payload: [
                "expression": .string(query),
                "value": .number(value),
            ]
        )
    }

    /// Minimal `a^b` for two numbers only.
    private static func evaluatePowerSimple(_ s: String) -> Double? {
        let parts = s.split(separator: "^", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, let base = Double(parts[0]), let exp = Double(parts[1]) else {
            return nil
        }
        return pow(base, exp)
    }

    // MARK: - Safe recursive-descent parser (+ - * / % and parentheses)

    private static func evaluateParsed(_ input: String) -> Double? {
        var tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        guard let value = parseExpression(&tokens), tokens.isEmpty else { return nil }
        return value
    }

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case lparen
        case rparen
    }

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch.isWhitespace {
                i = s.index(after: i)
                continue
            }
            if ch == "(" {
                tokens.append(.lparen)
                i = s.index(after: i)
                continue
            }
            if ch == ")" {
                tokens.append(.rparen)
                i = s.index(after: i)
                continue
            }
            if "+-*/%".contains(ch) {
                // Unary minus / plus after start, '(' or binary op.
                let unaryContext: Bool = {
                    guard let prev = tokens.last else { return true }
                    switch prev {
                    case .op, .lparen: return true
                    case .number, .rparen: return false
                    }
                }()
                if (ch == "-" || ch == "+"), unaryContext {
                    // Fold into following number if possible.
                    var j = s.index(after: i)
                    while j < s.endIndex, s[j].isWhitespace { j = s.index(after: j) }
                    if j < s.endIndex, s[j].isNumber || s[j] == "." {
                        var num = String(ch)
                        while j < s.endIndex, s[j].isNumber || s[j] == "." {
                            num.append(s[j])
                            j = s.index(after: j)
                        }
                        if let v = Double(num) {
                            tokens.append(.number(v))
                            i = j
                            continue
                        }
                    }
                }
                tokens.append(.op(ch))
                i = s.index(after: i)
                continue
            }
            if ch.isNumber || ch == "." {
                var j = i
                while j < s.endIndex, s[j].isNumber || s[j] == "." {
                    j = s.index(after: j)
                }
                let num = String(s[i..<j])
                guard let v = Double(num) else { return [] }
                tokens.append(.number(v))
                i = j
                continue
            }
            return [] // invalid character
        }
        return tokens
    }

    /// expression = term (('+'|'-') term)*
    private static func parseExpression(_ tokens: inout [Token]) -> Double? {
        guard var value = parseTerm(&tokens) else { return nil }
        while let t = tokens.first {
            guard case .op(let op) = t, op == "+" || op == "-" else { break }
            tokens.removeFirst()
            guard let rhs = parseTerm(&tokens) else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    /// term = factor (('*'|'/'|'%') factor)*
    private static func parseTerm(_ tokens: inout [Token]) -> Double? {
        guard var value = parseFactor(&tokens) else { return nil }
        while let t = tokens.first {
            guard case .op(let op) = t, op == "*" || op == "/" || op == "%" else { break }
            tokens.removeFirst()
            guard let rhs = parseFactor(&tokens) else { return nil }
            switch op {
            case "*": value *= rhs
            case "/":
                guard rhs != 0 else { return nil }
                value /= rhs
            case "%":
                guard rhs != 0 else { return nil }
                value = value.truncatingRemainder(dividingBy: rhs)
            default: return nil
            }
        }
        return value
    }

    /// factor = number | '(' expression ')'
    private static func parseFactor(_ tokens: inout [Token]) -> Double? {
        guard let t = tokens.first else { return nil }
        tokens.removeFirst()
        switch t {
        case .number(let n):
            return n
        case .lparen:
            guard let v = parseExpression(&tokens) else { return nil }
            guard case .rparen? = tokens.first else { return nil }
            tokens.removeFirst()
            return v
        default:
            return nil
        }
    }
}
