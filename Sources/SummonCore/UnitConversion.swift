import Foundation

/// Simple unit conversion (SP-13).
public enum UnitConversion {
    public static func convert(_ raw: String) -> SearchResult? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // e.g. "10 km to mi", "100 c to f", "5 kg to lb"
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count >= 4, parts[2] == "to",
              let value = Double(parts[0]) else { return nil }
        let from = parts[1]
        let to = parts[3]
        guard let out = convert(value: value, from: from, to: to) else { return nil }
        let text = String(format: "%.4g %@", out, to)
        return SearchResult(
            id: "unit:\(s)",
            title: text,
            subtitle: "\(value) \(from) → \(to)",
            kind: .calculation,
            score: 1.0,
            payload: ["value": .string(text)]
        )
    }

    public static func convert(value: Double, from: String, to: String) -> Double? {
        // Normalize to SI then out
        func lengthMeters(_ u: String) -> Double? {
            switch u {
            case "m", "meter", "meters": return 1
            case "km", "kilometer", "kilometers": return 1000
            case "mi", "mile", "miles": return 1609.344
            case "ft", "foot", "feet": return 0.3048
            case "in", "inch", "inches": return 0.0254
            default: return nil
            }
        }
        func massKg(_ u: String) -> Double? {
            switch u {
            case "kg", "kilogram", "kilograms": return 1
            case "g", "gram", "grams": return 0.001
            case "lb", "lbs", "pound", "pounds": return 0.45359237
            case "oz", "ounce", "ounces": return 0.028349523125
            default: return nil
            }
        }
        if from == "c" && to == "f" { return value * 9 / 5 + 32 }
        if from == "f" && to == "c" { return (value - 32) * 5 / 9 }
        if let a = lengthMeters(from), let b = lengthMeters(to) {
            return value * a / b
        }
        if let a = massKg(from), let b = massKg(to) {
            return value * a / b
        }
        return nil
    }
}
