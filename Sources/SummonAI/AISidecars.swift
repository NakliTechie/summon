import Foundation
import SummonCore

// Phase G — AI sidecars (staged only; no auto-exec).

/// Quick Fix: selection rewrite (RC-28).
public struct QuickFixSidecar: Sendable {
    public var rung: any ModelRung
    public init(rung: any ModelRung) { self.rung = rung }

    public func rewrite(selection: String, tone: String = "clear") async throws -> PersistedStagedProposal {
        let prompt = "Rewrite the following text. Tone: \(tone). Return only the rewrite.\n\n\(selection)"
        let out = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: out.text,
            egressSummary: out.egressSummary,
            state: "staged"
        )
    }
}

/// Screenshot → ask (OCR floor is deterministic; answer stages).
public struct ScreenshotAskSidecar: Sendable {
    public var rung: any ModelRung
    public init(rung: any ModelRung) { self.rung = rung }

    public func ask(ocrText: String, question: String) async throws -> PersistedStagedProposal {
        let prompt = "Screenshot OCR:\n\(ocrText)\n\nQuestion: \(question)\nAnswer briefly."
        let out = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: out.text,
            egressSummary: out.egressSummary,
            state: "staged"
        )
    }
}

/// Translate selection / bar text.
public struct TranslateSidecar: Sendable {
    public var rung: any ModelRung
    public init(rung: any ModelRung) { self.rung = rung }

    public func translate(text: String, to language: String) async throws -> PersistedStagedProposal {
        let prompt = "Translate to \(language). Return only the translation.\n\n\(text)"
        let out = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: out.text,
            egressSummary: out.egressSummary,
            state: "staged"
        )
    }
}

/// Dictation result holder (whisper/Apple Speech plug in later).
public struct DictationSidecar: Sendable {
    public init() {}
    public func stageTranscript(_ text: String) -> PersistedStagedProposal {
        PersistedStagedProposal(
            rung: "dictation",
            prompt: "(dictation)",
            output: text,
            egressSummary: "on-device",
            state: "staged"
        )
    }
}

/// NL → shell / calendar / window (staged).
public struct NLSurfaceSidecar: Sendable {
    public var rung: any ModelRung
    public init(rung: any ModelRung) { self.rung = rung }

    public func shell(from natural: String) async throws -> PersistedStagedProposal {
        let prompt = """
        Convert to a single zsh command. Return only the command line, no markdown.
        Request: \(natural)
        """
        let out = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: out.text.trimmingCharacters(in: .whitespacesAndNewlines),
            egressSummary: out.egressSummary,
            state: "staged"
        )
    }

    public func calendar(from natural: String) async throws -> PersistedStagedProposal {
        let prompt = """
        Extract a calendar event as JSON with keys title, startISO, endISO.
        Request: \(natural)
        """
        let out = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: out.text,
            egressSummary: out.egressSummary,
            state: "staged"
        )
    }
}

/// S3 embeddings placeholder (SP-23) — cosine over bag-of-words until real model.
public enum SemanticSearchS3 {
    public static func embed(_ text: String) -> [Double] {
        // Fixed 32-dim bag hash
        var v = [Double](repeating: 0, count: 32)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for t in tokens {
            var h = 0
            for u in t.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
            v[h % 32] += 1
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            v = v.map { $0 / norm }
        }
        return v
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    public static func rank(query: String, documents: [(id: String, text: String)], limit: Int = 20) -> [(id: String, score: Double)] {
        let qe = embed(query)
        return documents
            .map { ($0.id, cosine(qe, embed($0.text))) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}

/// L2 / L3 detection (ladder).
public struct LocalRuntimeDetect: Sendable, Equatable {
    public let ollama: Bool
    public let lmStudio: Bool
    public let hasBYOK: Bool

    public static func probe(
        ollamaURL: URL = URL(string: "http://127.0.0.1:11434")!,
        lmStudioURL: URL = URL(string: "http://127.0.0.1:1234")!,
        keychainHasProviderKey: Bool = false
    ) -> LocalRuntimeDetect {
        func up(_ url: URL) -> Bool {
            var req = URLRequest(url: url)
            req.timeoutInterval = 0.3
            req.httpMethod = "GET"
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    ok = true
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 0.4)
            return ok
        }
        return LocalRuntimeDetect(
            ollama: up(ollamaURL.appendingPathComponent("api/tags")),
            lmStudio: up(lmStudioURL),
            hasBYOK: keychainHasProviderKey
        )
    }
}
