import XCTest
@testable import SummonCore

/// The deterministic-surface battery — the launcher analogue of the overnight AI
/// battery. It drives 1000+ generated queries through the REAL headless surface
/// (`SearchService.search`) and buckets each outcome. Hard-failure buckets must be
/// empty: THREW (a plausible query aborted the launcher), MISCLASSIFIED (a known
/// capability produced the wrong kind), and BLED (agent-facing search leaked a
/// sensitive store). It coexists with `SearchServiceTests` — those are the smoke,
/// this is the scale. Gated (`SUMMON_RUN_BATTERY=1`) so it never slows `make verify`;
/// run it with `make battery`.
final class DeterministicSurfaceBatteryTests: XCTestCase {
    struct Finding: CustomStringConvertible {
        let category: String
        let input: String
        let problem: String
        var description: String { "[\(category)] \(problem) — input: \(inputPreview)" }
        private var inputPreview: String {
            input.count <= 60 ? input : String(input.prefix(57)) + "…"
        }
    }

    /// Per-search wall-clock ceiling for the in-memory surface (no mdfind). Above
    /// this a query is bucketed SLOW — a soft signal, not a hard failure.
    private let slowBudgetSeconds: Double = 0.05

    func testDeterministicSurfaceBattery() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_BATTERY"] == "1",
            "Set SUMMON_RUN_BATTERY=1 to run the deterministic-surface battery (make battery)."
        )

        var findings: [Finding] = []
        var counts: [String: Int] = [:]
        var slow = 0

        findings += runCalculator(counts: &counts, slow: &slow)
        findings += runUnitConversion(counts: &counts, slow: &slow)
        findings += runEmoji(counts: &counts, slow: &slow)
        findings += runSystemCommands(counts: &counts, slow: &slow)
        findings += try runSeededStores(counts: &counts, slow: &slow)
        findings += runObjectActionGrammar(counts: &counts)
        findings += try runSensitiveBleed(counts: &counts, slow: &slow)
        findings += try runFuzz(counts: &counts, slow: &slow)

        let total = counts.values.reduce(0, +)
        printReport(counts: counts, total: total, slow: slow, findings: findings)
        XCTAssertGreaterThanOrEqual(total, 1_000, "battery must exercise ≥1000 cases; ran \(total)")
        XCTAssertTrue(findings.isEmpty, "battery found \(findings.count) hard failures:\n"
            + findings.prefix(40).map(\.description).joined(separator: "\n"))
    }

    // MARK: - Calculator

    private func runCalculator(counts: inout [String: Int], slow: inout Int) -> [Finding] {
        var findings: [Finding] = []
        let operands = [0, 1, 2, 3, 7, 10, 42, 100, 256, 1_000, 9_999]
        let operators = ["+", "-", "*", "/", "^"]
        var n = 0
        for a in operands {
            for b in operands {
                for op in operators {
                    n += 1
                    let expr = "\(a) \(op) \(b)"
                    guard let value = Calculator.evaluate(expr) else { continue }
                    let expected = Calculator.format(value)
                    guard let row = Calculator.result(for: expr) else {
                        findings.append(Finding(category: "calc", input: expr,
                            problem: "evaluate produced \(value) but result(for:) was nil"))
                        continue
                    }
                    if row.title != expected {
                        findings.append(Finding(category: "calc", input: expr,
                            problem: "row title \"\(row.title)\" != formatted \"\(expected)\""))
                    }
                }
            }
        }
        // Malformed expressions must not crash and must not evaluate. ("1 ++ 2" is
        // intentionally excluded — lenient unary-plus parses it as 1 + (+2) = 3.)
        let malformed = ["2 +", "2 + ", "(", ")", "((1)", "* 3", "1 / 0",
                         String(repeating: "1+", count: 300) + "1"]
        for expr in malformed {
            n += 1
            if expr != "1 / 0", Calculator.evaluate(expr) != nil {
                findings.append(Finding(category: "calc", input: expr,
                    problem: "malformed expression evaluated to non-nil"))
            }
        }
        counts["calc"] = n
        return findings
    }

    // MARK: - Unit conversion

    private func runUnitConversion(counts: inout [String: Int], slow: inout Int) -> [Finding] {
        var findings: [Finding] = []
        let pairs = [("km", "miles"), ("miles", "km"), ("kg", "lb"), ("lb", "kg"),
                     ("c", "f"), ("f", "c"), ("m", "ft"), ("ft", "m"),
                     ("cm", "inch"), ("kb", "mb"), ("gb", "mb"), ("l", "gallon")]
        let values = [0.0, 1, 2.5, 10, 42, 100, 1_000]
        var n = 0
        for (from, to) in pairs {
            for value in values {
                n += 1
                let phrase = "\(value) \(from) to \(to)"
                if UnitConversion.convert(phrase) == nil,
                   UnitConversion.convert(value: value, from: from, to: to) != nil {
                    findings.append(Finding(category: "unit", input: phrase,
                        problem: "value-level convert works but phrase parse returned nil"))
                }
            }
        }
        counts["unit"] = n
        return findings
    }

    // MARK: - Emoji

    private func runEmoji(counts: inout [String: Int], slow: inout Int) -> [Finding] {
        var findings: [Finding] = []
        let core = makeCore()
        let names = ["rocket", "fire", "pray", "smile", "heart", "thumbs up", "star",
                     "check", "cross", "eyes", "wave", "clap", "tada", "bulb", "warning",
                     "lock", "key", "gear", "sparkles", "hundred"]
        var n = 0
        for name in names {
            n += 1
            let query = "\(name) kind:emoji"
            do {
                let results = try timed(core, query, slow: &slow)
                if let first = results.first, first.kind != .emoji {
                    findings.append(Finding(category: "emoji", input: query,
                        problem: "top result kind \(first.kind) != emoji"))
                }
            } catch {
                findings.append(Finding(category: "emoji", input: query,
                    problem: "search threw: \(error.localizedDescription)"))
            }
        }
        counts["emoji"] = n
        return findings
    }

    // MARK: - System commands

    private func runSystemCommands(counts: inout [String: Int], slow: inout Int) -> [Finding] {
        var findings: [Finding] = []
        let core = makeCore()
        let phrases = ["lock", "sleep", "empty trash", "log out", "restart", "shut down",
                       "screensaver", "display sleep", "settings", "about this mac"]
        var n = 0
        for phrase in phrases {
            n += 1
            let query = "\(phrase) kind:command"
            do {
                _ = try timed(core, query, slow: &slow)
            } catch {
                findings.append(Finding(category: "system", input: query,
                    problem: "search threw: \(error.localizedDescription)"))
            }
        }
        counts["system"] = n
        return findings
    }

    // MARK: - Seeded stores (snippets + quicklinks round-trip)

    private func runSeededStores(counts: inout [String: Int], slow: inout Int) throws -> [Finding] {
        var findings: [Finding] = []
        let core = try SummonCore.inMemory(appSearchPaths: [])
        for i in 0..<60 {
            _ = try core.dispatch(
                action: .snippetUpsert(id: "snip-\(i)", name: "batsnip\(i)",
                    body: "body \(i)", keyword: "bk\(i)"),
                actor: .user
            )
            _ = try core.dispatch(
                action: .quicklinkUpsert(id: "ql-\(i)", name: "batlink\(i)",
                    url: "https://example.com/\(i)", keyword: "bl\(i)"),
                actor: .user
            )
        }
        var n = 0
        for i in 0..<60 {
            n += 1
            let snipQuery = "batsnip\(i) kind:snippet"
            if let first = try timed(core, snipQuery, slow: &slow).first, first.kind != .snippet {
                findings.append(Finding(category: "snippet", input: snipQuery,
                    problem: "top result kind \(first.kind) != snippet"))
            }
            n += 1
            let linkQuery = "batlink\(i) kind:quicklink"
            if let first = try timed(core, linkQuery, slow: &slow).first, first.kind != .quicklink {
                findings.append(Finding(category: "quicklink", input: linkQuery,
                    problem: "top result kind \(first.kind) != quicklink"))
            }
        }
        counts["stores"] = n
        return findings
    }

    // MARK: - Object→action grammar (destructive-flag consistency)

    private func runObjectActionGrammar(counts: inout [String: Int]) -> [Finding] {
        var findings: [Finding] = []
        var n = 0
        for kind in [SearchResult.Kind.app, .file, .folder, .snippet, .calculation,
                     .setting, .command, .clipboard, .quicklink, .emoji] {
            let result = SearchResult(id: "obj:\(kind.rawValue)", title: "X", kind: kind,
                                      path: "/tmp/x", score: 1)
            let actions = ObjectActionGrammar.actions(for: result)
            n += 1
            if actions.isEmpty {
                findings.append(Finding(category: "object-action", input: kind.rawValue,
                    problem: "kind produced no actions"))
            }
            for action in actions {
                n += 1
                // Every action the grammar marks destructive must be one the
                // destructive guard also recognizes — no silent destructive path.
                if action.isDestructive, !DestructiveGuard.isDestructive(actionName: action.name) {
                    findings.append(Finding(category: "object-action", input: action.name,
                        problem: "grammar flags destructive but DestructiveGuard does not"))
                }
            }
        }
        counts["object-action"] = n
        return findings
    }

    // MARK: - Sensitive bleed (agent-facing search must never leak sensitive stores)

    private func runSensitiveBleed(counts: inout [String: Int], slow: inout Int) throws -> [Finding] {
        var findings: [Finding] = []
        let core = try SummonCore.inMemory(appSearchPaths: [])
        for i in 0..<40 {
            _ = try core.dispatch(
                action: .snippetUpsert(id: "s-\(i)", name: "secretsnip\(i)",
                    body: "password \(i)", keyword: "ss\(i)"),
                actor: .user
            )
            _ = try core.dispatch(
                action: .clipboardIngest(id: "c-\(i)", text: "secretclip\(i)",
                    sourceApp: "Test", createdAt: Date(), pinned: false),
                actor: .user
            )
        }
        // Queries that DO match the seeded sensitive data — the leak-prone case.
        var queries = (0..<40).flatMap { ["secretsnip\($0)", "secretclip\($0)", "ss\($0)"] }
        queries += ["secret", "password", "", "kind:snippet", "kind:clipboard"]
        var n = 0
        for query in queries {
            n += 1
            let results = try core.search.search(query, includeSensitiveStores: false)
            if let leaked = results.first(where: { $0.kind == .snippet || $0.kind == .clipboard }) {
                findings.append(Finding(category: "bleed", input: query,
                    problem: "agent-facing search leaked a \(leaked.kind.rawValue): \(leaked.title)"))
            }
        }
        counts["bleed"] = n
        return findings
    }

    // MARK: - Fuzz / adversarial (never throw, always bounded)

    private func runFuzz(counts: inout [String: Int], slow: inout Int) throws -> [Finding] {
        var findings: [Finding] = []
        let core = makeCore()
        var inputs: [String] = []
        inputs += ["'; DROP TABLE snippets;--", "${jndi:ldap://x}", "../../etc/passwd",
                   "<script>alert(1)</script>", "\u{0000}\u{0001}\u{0007}", "kind:",
                   "kind:bogus", "modified:<abc", "modified:>", ":::", "\\\\\\", "   ",
                   "\n\n\t", "😀😀😀😀😀😀😀😀", "日本語のクエリ", "🇮🇳🇮🇳🇮🇳"]
        inputs.append(String(repeating: "a", count: 5_000))
        inputs.append(String(repeating: "1+", count: 500))
        inputs.append(String(repeating: "kind:pdf ", count: 200))
        // Deterministic pseudo-random-looking noise (no RNG — index-derived).
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 :<>/.-_")
        for i in 0..<200 {
            var s = ""
            var x = i * 2_654_435_761 & 0x7fff_ffff
            for _ in 0..<((i % 40) + 1) {
                s.append(alphabet[x % alphabet.count])
                x = (x &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            }
            inputs.append(s)
        }
        var n = 0
        for input in inputs {
            n += 1
            do {
                let results = try timed(core, input, slow: &slow)
                if results.count > 50 {
                    findings.append(Finding(category: "fuzz", input: input,
                        problem: "returned \(results.count) rows, exceeds limit 50"))
                }
            } catch {
                findings.append(Finding(category: "fuzz", input: input,
                    problem: "search threw: \(error.localizedDescription)"))
            }
        }
        counts["fuzz"] = n
        return findings
    }

    // MARK: - Helpers

    private func makeCore() -> SummonCore {
        // A file-less spotlight keeps the run deterministic and host-independent.
        // force-try: an in-memory core with no app paths cannot fail to build.
        // swiftlint:disable:next force_try
        try! SummonCore.inMemory(spotlight: FakeSpotlightIndex(files: []), appSearchPaths: [])
    }

    private func timed(
        _ core: SummonCore,
        _ query: String,
        slow: inout Int
    ) throws -> [SearchResult] {
        let start = CFAbsoluteTimeGetCurrent()
        let results = try core.search.search(query)
        if CFAbsoluteTimeGetCurrent() - start > slowBudgetSeconds { slow += 1 }
        return results
    }

    private func printReport(counts: [String: Int], total: Int, slow: Int, findings: [Finding]) {
        print("── deterministic-surface battery ──")
        for key in counts.keys.sorted() {
            print(String(format: "  %-14@ %5d", key as NSString, counts[key] ?? 0))
        }
        print("  \(String(format: "%-14@", "TOTAL" as NSString)) \(total)")
        print("  slow(>\(Int(slowBudgetSeconds * 1000))ms): \(slow) · hard-failures: \(findings.count)")
    }
}
