import Foundation
@testable import SummonAI
import SummonCore
import XCTest

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Smart Paste extractor experiment over `Fixtures/smartpaste-resume-forms.json`.
///
/// Three legs: the deterministic floor (`EntityExtractor` + the deterministic
/// router), and Apple Foundation Models filling the form directly (one dynamic
/// schema per form) before and after the grounding guard. Each leg writes `fills-<leg>.json` into one folder, and
/// `testScoreEveryLeg` scores every such file with `ResumeFormFixture.score`,
/// so another extractor can join by writing its own file in the same shape.
///
/// Gated, in this order:
/// 1. `SUMMON_RESUME_EVAL_DIR=<dir> SUMMON_RUN_L1_LIVE=1 swift test --filter ResumeExtractorEvalTests/testRunOnDeviceLegs`
/// 2. `SUMMON_RESUME_EVAL_DIR=<dir> swift test --filter ResumeExtractorEvalTests/testScoreEveryLeg`
final class ResumeExtractorEvalTests: XCTestCase {
    struct LegFills: Codable {
        let leg: String
        let cases: [String: [String: String]]
        let latencyMs: [String: Double]
    }

    func testRunOnDeviceLegs() async throws {
        let dir = try evalDirectory()
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_L1_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_L1_LIVE=1 to run the Apple Foundation Models legs")
        }
        let fixture = try ResumeFormFixture.load()
        try write(await floorLeg(fixture), to: dir)
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Foundation Models needs macOS 26") }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Foundation Models is unavailable on this Mac")
        }
        for leg in try await FMLegs.directFill(fixture) { try write(leg, to: dir) }
        #endif
    }

    func testScoreEveryLeg() throws {
        let dir = try evalDirectory()
        let fixture = try ResumeFormFixture.load()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("fills-") && $0.hasSuffix(".json") }
            .sorted()
        XCTAssertFalse(files.isEmpty, "no fills-*.json in \(dir.path)")
        var rows: [[String: Any]] = []
        var lines = ["leg | correct / scored | " + fixture.cases.map(\.id).joined(separator: " | ") + " | median ms"]
        for file in files {
            let leg = try JSONDecoder().decode(LegFills.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
            let row = Self.score(leg, fixture: fixture)
            rows.append(row.json)
            lines.append(row.line)
        }
        let report = lines.joined(separator: "\n")
        print("Resume extractor scores\n" + report)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("scores.json"))
        try report.write(to: dir.appendingPathComponent("scores.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Scoring

    static func score(_ leg: LegFills, fixture: ResumeFormFixture) -> (json: [String: Any], line: String) {
        var correct = 0
        var scored = 0
        var perCase: [String] = []
        var misses: [String] = []
        for testCase in fixture.cases {
            let fills = leg.cases[testCase.id] ?? [:]
            let result = ResumeFormFixture.score(testCase, fills: fills)
            correct += result.correct
            scored += result.scored
            perCase.append("\(result.correct)/\(result.scored)")
            for (field, expectation) in testCase.expected.sorted(by: { $0.key < $1.key })
            where expectation.mode != "skip" && !ResumeFormFixture.matches(expectation, fill: fills[field]) {
                misses.append("\(testCase.id).\(field) = \(fills[field] ?? "∅")")
            }
        }
        let latencies = leg.latencyMs.values.sorted()
        let median = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        let line = "\(leg.leg) | \(correct) / \(scored) | " + perCase.joined(separator: " | ")
            + " | " + String(format: "%.0f", median)
        let json: [String: Any] = [
            "leg": leg.leg, "correct": correct, "scored": scored,
            "perCase": perCase, "medianMs": median, "misses": misses,
        ]
        return (json, line)
    }

    // MARK: Floor leg

    private func floorLeg(_ fixture: ResumeFormFixture) async -> LegFills {
        var cases: [String: [String: String]] = [:]
        var latency: [String: Double] = [:]
        for testCase in fixture.cases {
            guard let source = fixture.source(testCase.source), let form = fixture.form(testCase.form) else { continue }
            let started = Date()
            let entities = EntityExtractor().extract(from: source.text)
            let fields = form.fields.map {
                SmartPasteFieldDescriptor(id: $0.id, label: $0.label, isSecure: $0.secure == true)
            }
            let fills = (try? await DeterministicSmartPasteRouter().route(entities: entities, into: fields)) ?? []
            latency[testCase.id] = Date().timeIntervalSince(started) * 1000
            cases[testCase.id] = Dictionary(fills.map { ($0.fieldID, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        return LegFills(leg: "floor", cases: cases, latencyMs: latency)
    }

    // MARK: Plumbing

    private func evalDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SUMMON_RESUME_EVAL_DIR"], !path.isEmpty else {
            throw XCTSkip("set SUMMON_RESUME_EVAL_DIR to a folder to run the resume extractor experiment")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ leg: LegFills, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(leg).write(to: dir.appendingPathComponent("fills-\(leg.leg).json"))
    }
}

#if canImport(FoundationModels)
/// The Apple Foundation Models legs, run through the shipping generation
/// (`AppleFMFormFill`): `fm-direct` is the model's raw answer, `fm-guarded` the
/// same answer after `SmartPasteGrounding` drops what the text does not state.
@available(macOS 26.0, *)
enum FMLegs {
    static func directFill(_ fixture: ResumeFormFixture) async throws -> [ResumeExtractorEvalTests.LegFills] {
        var raw: [String: [String: String]] = [:]
        var guarded: [String: [String: String]] = [:]
        var latency: [String: Double] = [:]
        for testCase in fixture.cases {
            guard let source = fixture.source(testCase.source), let form = fixture.form(testCase.form) else { continue }
            let fields = form.fields.filter { $0.secure != true }.map {
                SmartPasteFieldDescriptor(id: $0.id, label: $0.label)
            }
            let started = Date()
            let answer = try await AppleFMFormFill.generate(sourceText: source.text, fields: fields)
            latency[testCase.id] = Date().timeIntervalSince(started) * 1000
            raw[testCase.id] = answer
            let kept = AppleFMSmartPasteRouter.groundedFills(answer, fields: fields, sourceText: source.text, entities: [])
            guarded[testCase.id] = Dictionary(kept.fills.map { ($0.fieldID, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        return [
            .init(leg: "fm-direct", cases: raw, latencyMs: latency),
            .init(leg: "fm-guarded", cases: guarded, latencyMs: latency),
        ]
    }
}

#endif
