import Foundation

/// Smart paste — value types shared across the layers.
///
/// Layer boundary (handoff §1): these types are headless and AppKit-free. The AX
/// read of a target app's fields and the AX write of an accepted fill live in
/// `SummonUI`; the model-backed router lives in `SummonAI`; the deterministic
/// floor and the proposal model live here so they are unit-testable with no
/// permission, no model, and no display.
///
/// The confidence vocabulary deliberately mirrors `verdict`'s `Decision`
/// contract (`~/Code/verdict`): a fill never claims a calibrated probability the
/// backend cannot produce. A deterministic match is `.heuristic`; a Foundation
/// Models decision is `.agreement` (sampling unanimity, no logits); only a
/// backend that reads logits earns `.decoded`.

/// Machine-recognizable content kinds. `NSDataDetector` supplies the first block
/// deterministically; `.name`/`.organization` are the residue an on-device model
/// fills in a later layer, never guessed by the deterministic floor.
public enum SmartPasteEntityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case email
    case phone
    case url
    case date
    case address
    case postalCode
    case number
    case currency
    case name
    case organization
    case text
}

/// One typed value extracted from the pasted text.
public struct SmartPasteEntity: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let kind: SmartPasteEntityKind
    /// The value to fill (normalized where a detector normalizes, e.g. a URL).
    public let value: String
    /// The exact substring it was drawn from (for display / provenance).
    public let raw: String
    /// UTF-16 offset + length in the source text; nil when not span-derived.
    public let location: Int?
    public let length: Int?

    public init(
        id: String = UUID().uuidString,
        kind: SmartPasteEntityKind,
        value: String,
        raw: String,
        location: Int? = nil,
        length: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.raw = raw
        self.location = location
        self.length = length
    }
}

/// A fillable target field as seen from the frontmost app's Accessibility tree
/// (or a fake in tests). The UI layer produces these; this layer only reads them.
public struct SmartPasteFieldDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// Stable per-target identity (an AX element path or ordinal). Opaque here.
    public let id: String
    /// AXTitle or the field's associated label, if any.
    public let label: String?
    /// AXPlaceholderValue, if any.
    public let placeholder: String?
    /// AXRole / AXSubrole hint (e.g. "AXTextField", "AXSecureTextField").
    public let role: String?
    /// A secure text field. Never proposed for auto-fill.
    public let isSecure: Bool
    /// The field's current value, if any (a non-empty field is deprioritized).
    public let currentValue: String?

    public init(
        id: String,
        label: String? = nil,
        placeholder: String? = nil,
        role: String? = nil,
        isSecure: Bool = false,
        currentValue: String? = nil
    ) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.role = role
        self.isSecure = isSecure
        self.currentValue = currentValue
    }

    /// The tokens a matcher searches: label, placeholder, and role, lowercased
    /// and split on non-alphanumerics.
    public var searchTokens: [String] {
        [label, placeholder, role]
            .compactMap { $0 }
            .flatMap { text in
                text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            }
    }
}

/// How much to trust a fill's confidence number — never overclaim.
public enum SmartPasteConfidenceKind: String, Sendable, Codable, Hashable {
    /// Deterministic label/kind match. The number is a match strength, not a probability.
    case heuristic
    /// Foundation Models sampling agreement (unanimity share). No logits.
    case agreement
    /// A backend that reads real distributions (e.g. verdict's Laya rung).
    case decoded
    /// No confidence available.
    case none
}

/// One proposed field ← entity mapping. Staged amber; filled only on explicit accept.
public struct SmartPasteFill: Sendable, Hashable, Codable, Identifiable {
    public var id: String { fieldID }
    public let fieldID: String
    public let entityID: String
    public let value: String
    /// 0...1. For `.heuristic` this is a match strength, not a calibrated probability.
    public let confidence: Double
    public let confidenceKind: SmartPasteConfidenceKind
    /// A short, human-readable reason (why this field got this entity).
    public let rationale: String

    public init(
        fieldID: String,
        entityID: String,
        value: String,
        confidence: Double,
        confidenceKind: SmartPasteConfidenceKind,
        rationale: String
    ) {
        self.fieldID = fieldID
        self.entityID = entityID
        self.value = value
        self.confidence = confidence
        self.confidenceKind = confidenceKind
        self.rationale = rationale
    }
}

/// A complete staged proposal: what was pasted, what was found, where it would go.
public struct SmartPasteProposal: Sendable, Hashable, Codable {
    public let sourceText: String
    public let entities: [SmartPasteEntity]
    public let fills: [SmartPasteFill]
    /// Provenance of the routing decision: "deterministic", "verdict:<model>", …
    public let generatedBy: String

    public init(
        sourceText: String,
        entities: [SmartPasteEntity],
        fills: [SmartPasteFill],
        generatedBy: String
    ) {
        self.sourceText = sourceText
        self.entities = entities
        self.fills = fills
        self.generatedBy = generatedBy
    }

    public var isEmpty: Bool { fills.isEmpty }
}

/// The routing seam. A deterministic implementation is the removable-AI floor;
/// a verdict-backed implementation (loopback typed decision) is a later layer.
/// A router never touches the pasteboard or Accessibility — it maps entities to
/// fields and returns proposed fills, ranked, for staging.
public protocol SmartPasteRouter: Sendable {
    func route(
        entities: [SmartPasteEntity],
        into fields: [SmartPasteFieldDescriptor]
    ) async throws -> [SmartPasteFill]
}
