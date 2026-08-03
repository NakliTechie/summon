import Foundation
import SummonCore

/// NL → command sidecar: parse model text into a schema-valid staged action.
/// Grading is deterministic (parseable + schema-valid), not string equality (C3).
public enum NLCommandSidecar {
    public struct ParsedCommand: Sendable, Equatable {
        public let actionName: String
        public let document: SchemaGate.ExternalActionDocument
        public let coreAction: CoreAction
    }

    /// Extract a single JSON object from free text (fenced or raw).
    public static func extractJSONObject(from text: String) -> Data? {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let slice = text[start...end]
            return String(slice).data(using: .utf8)
        }
        return text.data(using: .utf8)
    }

    /// Grade model output: must SchemaGate-decode to a known CoreAction.
    public static func parse(output: String, gate: SchemaGate = SchemaGate()) throws -> ParsedCommand {
        guard let data = extractJSONObject(from: output) else {
            throw ModelRungError.generationFailed("no JSON object in model output")
        }
        let action = try gate.decodeAction(from: data)
        let doc = try JSONDecoder().decode(SchemaGate.ExternalActionDocument.self, from: data)
        return ParsedCommand(actionName: action.name, document: doc, coreAction: action)
    }

    /// Prompt template for the model (staged; not executed).
    public static func systemPromptForNLCommand() -> String {
        """
        Output exactly one JSON object for Summon SchemaGate, nothing else.
        Shape: {"v":1,"action":"settings.set","key":"...","value":...}
        Supported actions: settings.set, settings.delete, snippet.upsert, snippet.delete,
        quicklink.upsert, quicklink.delete, clipboard.delete.
        """
    }
}
