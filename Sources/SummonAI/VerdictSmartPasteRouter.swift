import Foundation
import SummonCore

/// A `SmartPasteRouter` backed by the local `verdict` typed-decision daemon
/// (`~/Code/verdict`, loopback `POST /v1/systemone`, bearer token). It asks
/// verdict a `Choice` per unplaced entity whose options are the *live field
/// labels* — a catalogue discovered at paste time, so there is no "unseen field"
/// to fail on. verdict answers a schema-valid label with its honest confidence
/// kind (`.agreement` for Foundation Models, `.decoded` for Laya).
///
/// Layering (SUBSTANCE: cheapest correct step first): the deterministic floor
/// places what it can with certainty; verdict is asked only about the residue
/// (names, organisations, ambiguous fields). On ANY failure — daemon absent,
/// no token, timeout, non-200, undecodable — it returns the deterministic
/// result and never throws. Smart paste therefore works with verdict off
/// (removable-AI), and Summon never requires or launches it.
///
/// Egress: the loopback call must be authorized and journaled by the app layer
/// exactly as `LocalModelRung` does (`core.dispatch(.egressRequested)` →
/// `NetworkSovereignty.authorize`) before `LiveVerdictTransport` is used in the
/// shipping app. The transport is injectable so that authorization wraps it.
public struct VerdictSmartPasteRouter: SmartPasteRouter {
    private let transport: any VerdictTransport
    private let model: String
    private let fallback: any SmartPasteRouter

    /// verdict-fm wins on accuracy in verdict's own fixture (28/40 vs Laya 18/40);
    /// callers wanting decoded confidence pass "verdict-laya".
    public init(
        transport: any VerdictTransport,
        model: String = "verdict-fm",
        fallback: any SmartPasteRouter = DeterministicSmartPasteRouter()
    ) {
        self.transport = transport
        self.model = model
        self.fallback = fallback
    }

    public func route(
        entities: [SmartPasteEntity],
        into fields: [SmartPasteFieldDescriptor]
    ) async throws -> [SmartPasteFill] {
        // Cheapest correct step first: the deterministic floor.
        let floor = (try? await fallback.route(entities: entities, into: fields)) ?? []
        let placedFields = Set(floor.map(\.fieldID))
        let placedEntities = Set(floor.map(\.entityID))
        let remainingEntities = entities.filter { !placedEntities.contains($0.id) }
        let remainingFields = fields.filter { !$0.isSecure && !placedFields.contains($0.id) }
        guard !remainingEntities.isEmpty, !remainingFields.isEmpty else { return floor }

        // Ask verdict only about the residue. Any failure → the floor alone.
        guard let response = try? await ask(remainingEntities, remainingFields) else { return floor }
        let verdictFills = Self.fills(
            from: response,
            entities: remainingEntities,
            fields: remainingFields
        )
        return floor + verdictFills
    }

    // MARK: - Request

    private func ask(
        _ entities: [SmartPasteEntity],
        _ fields: [SmartPasteFieldDescriptor]
    ) async throws -> VerdictResponse {
        var criteria: [String: String] = [:]
        for field in fields {
            criteria[field.id] = field.label ?? field.placeholder ?? field.role ?? field.id
        }
        criteria[Self.noneKey] = "None of these fields"

        var questions: [String: VerdictQuestion] = [:]
        for (index, entity) in entities.enumerated() {
            questions["entity_\(index)"] = VerdictQuestion(
                type: "choice",
                instructions: "A form value \u{201C}\(entity.value)\u{201D} (a \(entity.kind.rawValue)). "
                    + "Which form field should receive it, or none?",
                criteria: criteria
            )
        }
        let state = entities.map { "\($0.kind.rawValue): \($0.value)" }.joined(separator: "\n")
        let request = VerdictRequest(model: model, state: state, questions: questions)
        let body = try JSONEncoder().encode(request)
        let data = try await transport.systemOne(body: body)
        return try JSONDecoder().decode(VerdictResponse.self, from: data)
    }

    // MARK: - Response → fills

    static let noneKey = "__none__"

    static func fills(
        from response: VerdictResponse,
        entities: [SmartPasteEntity],
        fields: [SmartPasteFieldDescriptor]
    ) -> [SmartPasteFill] {
        guard (response.failures ?? [:]).isEmpty else { return [] }
        let fieldIDs = Set(fields.map(\.id))
        var usedFields: Set<String> = []
        var fills: [SmartPasteFill] = []
        for (index, entity) in entities.enumerated() {
            guard let answer = response.answers["entity_\(index)"],
                  let choice = answer.choice,
                  choice != noneKey,
                  fieldIDs.contains(choice),
                  !usedFields.contains(choice) else { continue }
            // verdict already decided (a non-__none__ Choice); confidence rides
            // along for the staged-amber gate, it does not veto verdict's answer.
            let confidence = answer.confidence ?? 0.7
            usedFields.insert(choice)
            fills.append(
                SmartPasteFill(
                    fieldID: choice,
                    entityID: entity.id,
                    value: entity.value,
                    confidence: confidence,
                    confidenceKind: Self.kind(from: answer.confidenceKind),
                    rationale: "verdict routed a \(entity.kind.rawValue) to this field"
                )
            )
        }
        return fills
    }

    private static func kind(from raw: String?) -> SmartPasteConfidenceKind {
        switch raw {
        case "decoded": return .decoded
        case "agreement": return .agreement
        default: return .none
        }
    }
}

// MARK: - Transport

/// The loopback call to verdictd, as the router sees it. The shipping conformer
/// is `CoreAuthorizedVerdictTransport` (journaled egress → the declared
/// `VerdictHTTPTransport`); tests inject a fake. The router never touches the
/// network primitive itself.
public protocol VerdictTransport: Sendable {
    func systemOne(body: Data) async throws -> Data
}

// MARK: - Wire types

struct VerdictQuestion: Encodable {
    let type: String
    let instructions: String
    let criteria: [String: String]
}

struct VerdictRequest: Encodable {
    let model: String
    let state: String
    let questions: [String: VerdictQuestion]
}

struct VerdictResponse: Decodable {
    struct Answer: Decodable {
        let choice: String?
        let confidence: Double?
        let confidenceKind: String?
        enum CodingKeys: String, CodingKey {
            case choice
            case confidence
            case confidenceKind = "confidence_kind"
        }
    }
    let answers: [String: Answer]
    /// verdictd returns a map of question id → failure, empty on full success.
    let failures: [String: JSONValue]?
}
