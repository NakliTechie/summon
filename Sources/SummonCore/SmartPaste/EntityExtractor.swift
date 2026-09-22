import Foundation
import NaturalLanguage

/// Deterministic entity extraction over pasted text.
///
/// `NSDataDetector` is the OS's own detector — dates, links, phone numbers, and
/// addresses, no model, no network, sub-millisecond. This is the extraction
/// floor; a later layer adds an on-device model pass for the residue kinds
/// (`.name`, `.organization`) the detector cannot see. Keeping this layer purely
/// deterministic means smart paste extracts something useful even with no model
/// present (removable-AI).
public struct EntityExtractor: Sendable {
    /// Cap on input so a huge clip cannot stall detection; entities past it are
    /// not what a form fill needs. Callers pass a field-shaped snippet anyway.
    public static let maximumInputCharacters = 20_000

    public init() {}

    public func extract(from text: String) -> [SmartPasteEntity] {
        let trimmed = String(text.prefix(Self.maximumInputCharacters))
        guard !trimmed.isEmpty else { return [] }

        var entities: [SmartPasteEntity] = []
        var claimedRanges: [NSRange] = []

        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address, .date]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let full = NSRange(trimmed.startIndex..., in: trimmed)
            detector.enumerateMatches(in: trimmed, options: [], range: full) { match, _, _ in
                guard let match, let entity = Self.entity(from: match, in: trimmed) else { return }
                entities.append(entity)
                claimedRanges.append(match.range)
            }
        }

        // Standalone emails that arrive as bare text (not a mailto: link) — a
        // narrow, well-bounded regex over ranges the detector did not claim.
        for emailEntity in Self.emails(in: trimmed, excluding: claimedRanges) {
            entities.append(emailEntity)
            if let loc = emailEntity.location, let len = emailEntity.length {
                claimedRanges.append(NSRange(location: loc, length: len))
            }
        }

        // Person and organization names — on-device linguistics (no model, no
        // network, no latency). This is the residue NSDataDetector cannot see;
        // it is what lets a name reach a "Full name" field and an org a "Company".
        for nameEntity in Self.names(in: trimmed, excluding: claimedRanges) {
            entities.append(nameEntity)
        }

        return entities.sorted { ($0.location ?? 0) < ($1.location ?? 0) }
    }

    /// Personal and organization names via `NLTagger` `.nameType` — Apple's
    /// on-device named-entity recognition, synchronous and instant.
    private static func names(in text: String, excluding claimed: [NSRange]) -> [SmartPasteEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        var out: [SmartPasteEntity] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            let kind: SmartPasteEntityKind
            switch tag {
            case .personalName: kind = .name
            case .organizationName: kind = .organization
            default: return true
            }
            let nsRange = NSRange(range, in: text)
            if claimed.contains(where: { NSIntersectionRange($0, nsRange).length > 0 }) { return true }
            let value = String(text[range])
            guard !value.isEmpty else { return true }
            out.append(
                SmartPasteEntity(
                    kind: kind, value: value, raw: value,
                    location: nsRange.location, length: nsRange.length
                )
            )
            return true
        }
        return out
    }

    private static func entity(
        from match: NSTextCheckingResult,
        in text: String
    ) -> SmartPasteEntity? {
        guard let range = Range(match.range, in: text) else { return nil }
        let raw = String(text[range])
        let location = match.range.location
        let length = match.range.length

        switch match.resultType {
        case .link:
            guard let url = match.url else { return nil }
            if url.scheme == "mailto" {
                let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                return SmartPasteEntity(
                    kind: .email, value: address, raw: raw, location: location, length: length
                )
            }
            return SmartPasteEntity(
                kind: .url, value: url.absoluteString, raw: raw, location: location, length: length
            )
        case .phoneNumber:
            let value = match.phoneNumber ?? raw
            return SmartPasteEntity(
                kind: .phone, value: value, raw: raw, location: location, length: length
            )
        case .address:
            return SmartPasteEntity(
                kind: .address, value: raw, raw: raw, location: location, length: length
            )
        case .date:
            return SmartPasteEntity(
                kind: .date, value: raw, raw: raw, location: location, length: length
            )
        default:
            return nil
        }
    }

    /// A conservative email match. Detects the common shape without trying to be
    /// RFC-complete; the detector already caught mailto: links, so this only
    /// covers bare addresses in unclaimed ranges.
    private static func emails(in text: String, excluding claimed: [NSRange]) -> [SmartPasteEntity] {
        let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        var out: [SmartPasteEntity] = []
        for match in regex.matches(in: text, options: [], range: full) {
            if claimed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])
            out.append(
                SmartPasteEntity(
                    kind: .email,
                    value: raw,
                    raw: raw,
                    location: match.range.location,
                    length: match.range.length
                )
            )
        }
        return out
    }
}
