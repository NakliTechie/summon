import Foundation

/// Inline calculator for the launcher bar (M1). Deterministic; no AI.
///
/// **Never** feed incomplete input to `NSExpression` — e.g. `"2 +"` raises an
/// uncaught `NSException` and aborts the process (crash 2026-08-04).
public enum Calculator {
    static let maximumInputCharacters = 512
    static let maximumTokenCount = 256
    static let maximumNestingDepth = 64

    /// True when the query looks like a *complete* arithmetic expression.
    public static func looksLikeExpression(_ raw: String) -> Bool {
        let s = normalized(raw)
        guard !s.isEmpty, s.count <= maximumInputCharacters else { return false }
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
            if depth > maximumNestingDepth { return false }
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
        let s = normalized(raw)
        guard looksLikeExpression(s) else { return nil }
        guard let value = evaluateParsed(s), value.isFinite else { return nil }
        return value
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

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
    }

    // MARK: - Bounded recursive-descent parser

    private static func evaluateParsed(_ input: String) -> Double? {
        guard let tokens = tokenize(input), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value
    }

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case lparen
        case rparen
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard tokens.count < maximumTokenCount else { return nil }
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
            if "+-*/%^".contains(ch) {
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
                guard let v = Double(num), v.isFinite else { return nil }
                tokens.append(.number(v))
                i = j
                continue
            }
            return nil
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var nestingDepth = 0

        var isAtEnd: Bool { index == tokens.count }

        /// expression = term (('+'|'-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let operation = matchingOperator(["+", "-"]) {
                guard let rhs = parseTerm() else { return nil }
                value = operation == "+" ? value + rhs : value - rhs
                guard value.isFinite else { return nil }
            }
            return value
        }

        /// term = unary (('*'|'/'|'%') unary)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let operation = matchingOperator(["*", "/", "%"]) {
                guard let rhs = parseUnary() else { return nil }
                switch operation {
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { return nil }
                    value /= rhs
                case "%":
                    guard rhs != 0 else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                default: return nil
                }
                guard value.isFinite else { return nil }
            }
            return value
        }

        /// unary = ('+'|'-') unary | power
        private mutating func parseUnary() -> Double? {
            if let operation = matchingOperator(["+", "-"]) {
                guard let value = parseUnary() else { return nil }
                return operation == "-" ? -value : value
            }
            return parsePower()
        }

        /// power = primary ('^' unary)?; the recursive RHS makes exponentiation right-associative.
        private mutating func parsePower() -> Double? {
            guard let base = parsePrimary() else { return nil }
            guard matchingOperator(["^"]) != nil else { return base }
            guard let exponent = parseUnary() else { return nil }
            let value = pow(base, exponent)
            return value.isFinite ? value : nil
        }

        /// primary = number | '(' expression ')'
        private mutating func parsePrimary() -> Double? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let number):
                return number
            case .lparen:
                nestingDepth += 1
                guard nestingDepth <= Calculator.maximumNestingDepth else { return nil }
                guard let value = parseExpression(), consumeRightParenthesis() else { return nil }
                nestingDepth -= 1
                return value
            case .op, .rparen:
                return nil
            }
        }

        private mutating func matchingOperator(_ accepted: Set<Character>) -> Character? {
            guard index < tokens.count, case .op(let operation) = tokens[index],
                  accepted.contains(operation) else {
                return nil
            }
            index += 1
            return operation
        }

        private mutating func consumeRightParenthesis() -> Bool {
            guard index < tokens.count, tokens[index] == .rparen else { return false }
            index += 1
            return true
        }
    }
}
