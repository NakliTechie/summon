import Foundation

/// Inline calculator for the launcher bar (M1). Deterministic; no AI.
public enum Calculator {
    /// True when the query looks like an arithmetic expression rather than a search phrase.
    public static func looksLikeExpression(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        // Must contain an operator or be a pure number; reject pure words.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/()%^ ")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasDigit = s.contains { $0.isNumber }
        let hasOp = s.contains { "+-*/%^".contains($0) }
        return hasDigit && (hasOp || Double(s) != nil)
    }

    /// Evaluate a simple arithmetic expression. Returns nil if not evaluable.
    public static func evaluate(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeExpression(s) else { return nil }
        // Normalize ^ to ** not supported by NSExpression; use pow via string rewrite for simple a^b.
        let exprString = s.replacingOccurrences(of: "^", with: "**")
        // NSExpression does not support **; handle only + - * / % ( ) .
        let safe = exprString.replacingOccurrences(of: "**", with: "")
        // If user used ^ we already stripped to empty power — reject bare ^ for v1.
        if s.contains("^") {
            return evaluatePowerSimple(s)
        }
        let expr = NSExpression(format: safe)
        guard let value = expr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }
        return value.doubleValue
    }

    public static func format(_ value: Double) -> String {
        if value.rounded() == value, value >= Double(Int64.min), value <= Double(Int64.max) {
            return String(Int64(value))
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
}
