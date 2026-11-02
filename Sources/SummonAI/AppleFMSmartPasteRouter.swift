import Foundation
import SummonCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Smart paste with Apple Foundation Models filling the form directly: one
/// generation per paste, a schema with one string per field, the copied text as
/// the prompt (decided 2026-10-31: 84/99 on the resume fixture against 36/99 for
/// the deterministic floor).
///
/// Every value the model writes passes `SmartPasteGrounding` first, so a value
/// the copied text does not state is dropped, never filled. Fields the model
/// leaves empty go to `fallback` (verdict, then the floor), which also takes the
/// whole paste when the model is unavailable, too slow, or fails. Smart paste
/// therefore still works with Apple Intelligence off (removable AI).
public struct AppleFMSmartPasteRouter: SmartPasteRouter {
    /// Copied text and the fields to fill → field id → value ("" or absent = not stated).
    public typealias Generate = @Sendable (String, [SmartPasteFieldDescriptor]) async throws -> [String: String]

    /// A form with more fields than this goes to the fallback: the schema would
    /// crowd the on-device model's context.
    static let maxFields = 48
    /// Copied text longer than this goes to the fallback, for the same reason.
    static let maxSourceCharacters = 8_000

    private let generate: Generate
    private let fallback: any SmartPasteRouter
    private let timeoutSeconds: Double

    public init(generate: @escaping Generate, fallback: any SmartPasteRouter, timeoutSeconds: Double = 15) {
        self.generate = generate
        self.fallback = fallback
        self.timeoutSeconds = timeoutSeconds
    }

    /// Without the copied text there is nothing for the model to read.
    public func route(
        entities: [SmartPasteEntity],
        into fields: [SmartPasteFieldDescriptor]
    ) async throws -> [SmartPasteFill] {
        try await fallback.route(entities: entities, into: fields)
    }

    public func route(
        sourceText: String,
        entities: [SmartPasteEntity],
        into fields: [SmartPasteFieldDescriptor]
    ) async throws -> [SmartPasteFill] {
        let eligible = fields.filter { !$0.isSecure }
        guard !eligible.isEmpty, eligible.count <= Self.maxFields,
              sourceText.count <= Self.maxSourceCharacters else {
            UsageLog.record("smartpaste.fm.skipped", [
                "fields": String(eligible.count), "sourceChars": String(sourceText.count),
            ])
            return try await fallback.route(sourceText: sourceText, entities: entities, into: fields)
        }

        let span = UsageLog.span("smartpaste.fm", ["fields": String(eligible.count)])
        let raw: [String: String]
        do {
            raw = try await withTimeout(timeoutSeconds) { [generate] in try await generate(sourceText, eligible) }
        } catch {
            span.fail(error)
            return try await fallback.route(sourceText: sourceText, entities: entities, into: fields)
        }
        let (fills, dropped) = Self.groundedFills(raw, fields: eligible, sourceText: sourceText, entities: entities)
        span.end([
            "filled": String(fills.count),
            "dropped": dropped.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " | "),
        ])

        // The model's empty fields go to the fallback, minus any value the model
        // already placed, so one value never lands in two fields.
        let filledIDs = Set(fills.map(\.fieldID))
        let placed = Set(fills.map { SmartPasteGrounding.normalized($0.value) })
        let rest = eligible.filter { !filledIDs.contains($0.id) }
        guard !rest.isEmpty else { return fills }
        let residue = (try? await fallback.route(sourceText: sourceText, entities: entities, into: rest)) ?? []
        return fills + residue.filter { !placed.contains(SmartPasteGrounding.normalized($0.value)) }
    }

    /// Keep each non-empty value the copied text states; report the rest.
    static func groundedFills(
        _ raw: [String: String],
        fields: [SmartPasteFieldDescriptor],
        sourceText: String,
        entities: [SmartPasteEntity]
    ) -> (fills: [SmartPasteFill], dropped: [String: String]) {
        var fills: [SmartPasteFill] = []
        var dropped: [String: String] = [:]
        for field in fields {
            guard let value = raw[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            guard SmartPasteGrounding.isGrounded(value, in: sourceText) else {
                dropped[field.id] = value
                continue
            }
            let key = SmartPasteGrounding.normalized(value)
            let entity = entities.first { SmartPasteGrounding.normalized($0.value) == key }
            fills.append(SmartPasteFill(
                fieldID: field.id,
                entityID: entity?.id ?? "fm:\(field.id)",
                value: value,
                // One greedy sample: no agreement share and no logits to report.
                confidence: 0.8,
                confidenceKind: .none,
                rationale: "Apple Foundation Models copied this from the text"
            ))
        }
        return (fills, dropped)
    }

    private func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ModelRungError.generationFailed("Apple Foundation Models took longer than \(Int(seconds)) s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ModelRungError.generationFailed("no form-fill result")
            }
            return first
        }
    }
}

#if canImport(FoundationModels)
/// The on-device generation behind `AppleFMSmartPasteRouter`. Greedy sampling,
/// so the same paste reads the same way twice.
@available(macOS 26.0, *)
public enum AppleFMFormFill {
    public static let instructions = """
        You fill in a form from the text the user copied. For each form field, copy the value \
        exactly as the text states it. When the text does not state a value for a field, return \
        an empty string for that field. Never invent, guess, or write new text, and never work a \
        value out from today's date.
        """

    public static func generate(
        sourceText: String,
        fields: [SmartPasteFieldDescriptor]
    ) async throws -> [String: String] {
        guard case .available = SystemLanguageModel.default.availability else {
            throw ModelRungError.unavailable(.appleFM, "Apple Foundation Models is unavailable")
        }
        let root = DynamicGenerationSchema(
            name: "FormFill",
            description: "The value for each form field, or an empty string when the text does not state it.",
            properties: fields.enumerated().map { index, field in
                DynamicGenerationSchema.Property(
                    name: field.id,
                    description: describe(field, position: index + 1, of: fields.count),
                    schema: DynamicGenerationSchema(type: String.self)
                )
            }
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let response = try await session.respond(
            to: "Copied text:\n\(sourceText)", schema: schema, options: GenerationOptions(sampling: .greedy)
        )
        return strings(in: response.content.jsonString)
    }

    /// What the model reads about one field: its label, placeholder, nearby
    /// text, and position in the form, so a row labelled only "home" can still
    /// be read in order (a Contacts card lists phones before emails).
    static func describe(_ field: SmartPasteFieldDescriptor, position: Int, of count: Int) -> String {
        var parts: [String] = []
        if let label = field.label, !label.isEmpty { parts.append("labelled \"\(label)\"") }
        if let placeholder = field.placeholder, !placeholder.isEmpty, placeholder != field.label {
            parts.append("placeholder \"\(placeholder)\"")
        }
        if let context = field.context, !context.isEmpty { parts.append("next to \"\(context)\"") }
        if parts.isEmpty { parts.append("with no label") }
        return "Form field " + parts.joined(separator: ", ") + "; field \(position) of \(count)"
    }

    static func strings(in json: String) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { result[key] = text }
        }
        return result
    }
}
#endif
