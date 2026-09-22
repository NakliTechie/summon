import Foundation

/// The no-model routing floor: match entity kinds to fields by their labels,
/// placeholders, and roles. This is what runs when no model rung and no verdict
/// daemon are available (removable-AI), and it is the fallback a model-backed
/// router drops to for any field it cannot confidently place.
///
/// Design stance, from the JEV/smart-paste captures: a tiny trained decider
/// fails on field types outside its catalogue (the iPaste X/GitHub-field gap).
/// This matcher instead *fails closed* — a field with no kind match gets no fill,
/// never a guess — and the staged-amber accept step means even a confident match
/// is a proposal, not an action.
public struct DeterministicSmartPasteRouter: SmartPasteRouter {
    /// Fills below this strength are dropped rather than staged as noise.
    public let confidenceFloor: Double

    public init(confidenceFloor: Double = 0.5) {
        self.confidenceFloor = confidenceFloor
    }

    public func route(
        entities: [SmartPasteEntity],
        into fields: [SmartPasteFieldDescriptor]
    ) async throws -> [SmartPasteFill] {
        Self.match(entities: entities, fields: fields, confidenceFloor: confidenceFloor)
    }

    /// Pure, synchronous core — the unit under test.
    static func match(
        entities: [SmartPasteEntity],
        fields: [SmartPasteFieldDescriptor],
        confidenceFloor: Double
    ) -> [SmartPasteFill] {
        // Score every (field, entity) pair, then assign greedily by strength so
        // each entity and each field is used at most once.
        struct Candidate { let field: String; let entity: String; let value: String; let score: Double; let reason: String }
        var candidates: [Candidate] = []

        for field in fields {
            guard !field.isSecure else { continue } // never auto-fill secure fields
            let tokens = Set(field.searchTokens)
            for entity in entities {
                guard let (score, reason) = strength(of: entity.kind, against: tokens) else { continue }
                candidates.append(
                    Candidate(
                        field: field.id,
                        entity: entity.id,
                        value: entity.value,
                        score: score,
                        reason: reason
                    )
                )
            }
        }

        candidates.sort { $0.score > $1.score }
        var usedFields: Set<String> = []
        var usedEntities: Set<String> = []
        var fills: [SmartPasteFill] = []
        for candidate in candidates {
            guard candidate.score >= confidenceFloor else { break } // sorted; nothing below survives
            guard !usedFields.contains(candidate.field),
                  !usedEntities.contains(candidate.entity) else { continue }
            usedFields.insert(candidate.field)
            usedEntities.insert(candidate.entity)
            fills.append(
                SmartPasteFill(
                    fieldID: candidate.field,
                    entityID: candidate.entity,
                    value: candidate.value,
                    confidence: candidate.score,
                    confidenceKind: .heuristic,
                    rationale: candidate.reason
                )
            )
        }
        return fills
    }

    /// The kind → field-token lexicon. Returns a match strength and a reason, or
    /// nil when this entity kind does not belong in a field with these tokens.
    private static func strength(
        of kind: SmartPasteEntityKind,
        against tokens: Set<String>
    ) -> (Double, String)? {
        for (cue, weight) in lexicon(for: kind) where tokens.contains(cue) {
            return (weight, "field labelled \u{201C}\(cue)\u{201D} matches a \(kind.rawValue)")
        }
        return nil
    }

    /// Field-label cues per entity kind, each with a match strength. Strong,
    /// unambiguous cues score high; weaker or shared cues score at the floor.
    private static func lexicon(for kind: SmartPasteEntityKind) -> [(String, Double)] {
        switch kind {
        case .email:
            return [("email", 0.95), ("e", 0.5), ("mail", 0.8)]
        case .phone:
            return [("phone", 0.95), ("mobile", 0.9), ("cell", 0.9), ("tel", 0.85), ("telephone", 0.9), ("fax", 0.7)]
        case .url:
            return [("url", 0.9), ("website", 0.9), ("site", 0.7), ("link", 0.7), ("web", 0.7), ("homepage", 0.85)]
        case .date:
            return [("date", 0.85), ("dob", 0.95), ("birth", 0.9), ("birthday", 0.9), ("expiry", 0.8), ("expiration", 0.8)]
        case .address:
            return [("address", 0.9), ("street", 0.9), ("addr", 0.85)]
        case .postalCode:
            return [("zip", 0.95), ("postal", 0.9), ("postcode", 0.9)]
        case .number:
            return [("number", 0.6), ("amount", 0.7), ("quantity", 0.7), ("qty", 0.7)]
        case .currency:
            return [("price", 0.85), ("amount", 0.85), ("cost", 0.8), ("total", 0.75)]
        case .name:
            return [("name", 0.8), ("fullname", 0.9), ("firstname", 0.85), ("lastname", 0.85), ("contact", 0.6)]
        case .organization:
            return [("company", 0.9), ("organization", 0.9), ("organisation", 0.9), ("employer", 0.85), ("org", 0.8)]
        case .text:
            return [] // never auto-place free text; that is the model's residue job
        }
    }
}
