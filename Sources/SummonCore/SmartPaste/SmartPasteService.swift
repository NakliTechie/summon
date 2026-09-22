import Foundation

/// Orchestrates one smart-paste cycle and bridges it onto the shared staging
/// spine. Headless: it takes field descriptors from a `SmartPasteTarget` and a
/// `SmartPasteRouter`, never Accessibility directly, so the whole flow —
/// extract → route → stage → accept → apply — is unit-testable against a fake
/// target and an in-memory store.
///
/// Staging reuses `PersistedStagedProposal` rather than a parallel store: one
/// amber spine (invariant — propose-don't-dispose), one review surface, one
/// recovery path. The `SmartPasteProposal` rides in the proposal's `output` as
/// JSON; `rung` marks it as smart paste so the reviewer can tell it apart from a
/// generated-text proposal.
public struct SmartPasteService: Sendable {
    /// The `rung` value that marks a staged proposal as smart paste.
    public static let rung = "smartpaste"

    private let extractor: EntityExtractor

    public init(extractor: EntityExtractor = EntityExtractor()) {
        self.extractor = extractor
    }

    /// Extract entities from the pasted text and route them into the target's
    /// fields. Produces a proposal; never stages, writes, or touches the target
    /// beyond the fields it was given.
    public func propose(
        sourceText: String,
        fields: [SmartPasteFieldDescriptor],
        router: SmartPasteRouter
    ) async throws -> SmartPasteProposal {
        let entities = extractor.extract(from: sourceText)
        let fills = entities.isEmpty || fields.isEmpty
            ? []
            : try await router.route(entities: entities, into: fields)
        return SmartPasteProposal(
            sourceText: sourceText,
            entities: entities,
            fills: fills,
            generatedBy: fills.isEmpty ? "none" : provenance(of: router)
        )
    }

    /// Read the target's fields, propose against them, and stage the proposal
    /// for explicit review. Returns the staged proposal id, or nil when there is
    /// nothing to propose (no entities, or no confident fill) — nothing is
    /// staged in that case. Applies nothing: acceptance is a separate step.
    @discardableResult
    public func proposeAndStage(
        sourceText: String,
        target: SmartPasteTarget,
        router: SmartPasteRouter,
        store: StagedProposalStore
    ) async throws -> String? {
        let fields = try target.fields()
        let proposal = try await propose(sourceText: sourceText, fields: fields, router: router)
        guard !proposal.isEmpty else { return nil }
        let persisted = try Self.persisted(from: proposal)
        try store.upsert(persisted)
        return persisted.id
    }

    /// A field id → display label map, tolerant of duplicate ids (first wins).
    /// The review surface builds this per proposal; `Dictionary(uniqueKeysWithValues:)`
    /// traps on a duplicate key, so a malformed target with colliding ids must not
    /// reach that constructor. Field ids are expected unique; this fails safe if not.
    public static func fieldLabels(for fields: [SmartPasteFieldDescriptor]) -> [String: String] {
        Dictionary(
            fields.map { ($0.id, $0.label ?? $0.placeholder ?? $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func provenance(of router: SmartPasteRouter) -> String {
        if router is DeterministicSmartPasteRouter { return "deterministic" }
        return String(describing: type(of: router))
    }

    // MARK: - Bridge to the staging spine

    /// Wrap a `SmartPasteProposal` as a `PersistedStagedProposal`. The source
    /// text is the `prompt`; the proposal JSON is the `output`; a loopback model
    /// call leaves the machine's egress empty (on-device).
    public static func persisted(from proposal: SmartPasteProposal) throws -> PersistedStagedProposal {
        let data = try JSONEncoder().encode(proposal)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CoreError.store("smart-paste proposal is not encodable")
        }
        return PersistedStagedProposal(
            rung: rung,
            prompt: String(proposal.sourceText.prefix(4_000)),
            output: json,
            egressSummary: ""
        )
    }

    /// Recover the `SmartPasteProposal` from a staged proposal's `output`.
    public static func proposal(from persisted: PersistedStagedProposal) throws -> SmartPasteProposal {
        guard persisted.rung == rung else {
            throw CoreError.store("proposal \(persisted.id) is not a smart-paste proposal")
        }
        guard let data = persisted.output.data(using: .utf8) else {
            throw CoreError.store("smart-paste proposal \(persisted.id) has an undecodable output")
        }
        return try JSONDecoder().decode(SmartPasteProposal.self, from: data)
    }
}
