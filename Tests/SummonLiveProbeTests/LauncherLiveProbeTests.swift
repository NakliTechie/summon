import AppKit
import XCTest
import SummonCore
import SummonAI
@testable import SummonUI

/// Live front-end probe: drives the real `LauncherPanelController` through the
/// real Apple Foundation Model — the same UI + AI wiring the shipping app uses —
/// and asserts the answer card renders. Gated on SUMMON_RUN_L1_LIVE=1 so it only
/// runs on the gate host on demand (skipped in `make verify`). Automated
/// stand-in for a pixel drive of the ⌥Space panel, which can't be
/// screen-automated (Summon is an LSUIElement menu-bar agent). Synchronous +
/// RunLoop-driven so the panel's main-actor continuations actually fire.
final class LauncherLiveProbeTests: XCTestCase {
    func testLauncherRendersRealAnswerAndWebSearch() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_L1_LIVE"] == "1",
            "live probe: set SUMMON_RUN_L1_LIVE=1 on the gate host"
        )
        let core = try SummonCore.inMemory()
        let service = SummonAIService(core: core)
        let integration = LauncherAIIntegration(
            handler: { prompt in
                let response = try await service.respond(prompt: prompt, actor: .user)
                switch response.kind {
                case let .answer(text):
                    return .answer(text: text, rung: response.rung.rawValue,
                                   egressSummary: response.egressSummary)
                case let .staged(proposalID):
                    return .staged(proposalID: proposalID, rung: response.rung.rawValue,
                                   egressSummary: response.egressSummary)
                case let .performed(text):
                    return .performed(text: text)
                }
            },
            searchHandler: { prompt, _ in
                guard let core = service.core else { return .unavailable }
                if !core.webConfig.enabled {
                    core.webConfig.enabled = true
                    _ = try? core.persistWebConfig(actor: .user)
                }
                switch try await service.searchAndAnswer(
                    query: prompt, provider: WikipediaSearchClient(), allowOnce: true, actor: .user
                ) {
                case let .answer(text, rung, sources):
                    return .answer(text: text, sources: sources.map { "\($0.title) — \($0.url)" },
                                   rung: rung.rawValue)
                case let .needsConsent(host): return .needsConsent(host: host)
                case .noResults: return .noResults
                case .disabled: return .unavailable
                }
            }
        )
        let panel = LauncherPanelController(core: core, aiIntegration: integration)

        // 1) Local-tool answer path.
        panel.runAI(confirmation(action: "ai.ask", prompt: "what is my battery status"))
        pump(until: { !panel.aiAnswerView.isHidden && !panel.aiAnswerView.answer.isEmpty }, timeout: 30)
        let answer = panel.aiAnswerView.answer
        print("PROBE local answer -> \(answer)")
        XCTAssertFalse(answer.isEmpty, "answer card should render a real answer")
        panel.hide()

        // 2) Web-search + on-device synthesis path (allow-once, no modal).
        panel.runWebSearch(confirmation(action: "web.search", prompt: "who wrote the book 1984"),
                           allowOnce: true)
        pump(until: {
            !panel.aiAnswerView.isHidden && panel.aiAnswerView.answer.contains("Sources")
        }, timeout: 40)
        let web = panel.aiAnswerView.answer
        print("PROBE web answer -> \(web)")
        XCTAssertTrue(web.contains("Sources"), "web answer should render sources")
        panel.hide()
    }

    /// #2: a local answer lands fast, then is refined against the web in parallel
    /// — but only once sticky web consent exists. Drives the real panel and asserts
    /// the card ends web-grounded (carries Sources).
    func testLocalAnswerRefinesAgainstWebWhenConsentSticky() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_L1_LIVE"] == "1",
            "live probe: set SUMMON_RUN_L1_LIVE=1 on the gate host"
        )
        let core = try SummonCore.inMemory()
        let service = SummonAIService(core: core)
        let integration = LauncherAIIntegration(
            handler: { prompt in
                let response = try await service.respond(prompt: prompt, actor: .user)
                switch response.kind {
                case let .answer(text):
                    return .answer(text: text, rung: response.rung.rawValue,
                                   egressSummary: response.egressSummary)
                case let .staged(proposalID):
                    return .staged(proposalID: proposalID, rung: response.rung.rawValue,
                                   egressSummary: response.egressSummary)
                case let .performed(text):
                    return .performed(text: text)
                }
            },
            searchHandler: { prompt, _ in
                guard let core = service.core else { return .unavailable }
                if !core.webConfig.enabled {
                    core.webConfig.enabled = true
                    _ = try? core.persistWebConfig(actor: .user)
                }
                switch try await service.searchAndAnswer(
                    query: prompt, provider: WikipediaSearchClient(), allowOnce: true, actor: .user
                ) {
                case let .answer(text, rung, sources):
                    return .answer(text: text, sources: sources.map { "\($0.title) — \($0.url)" },
                                   rung: rung.rawValue)
                case let .needsConsent(host): return .needsConsent(host: host)
                case .noResults: return .noResults
                case .disabled: return .unavailable
                }
            },
            // Sticky consent already granted → the augment leg is allowed to fire.
            consentIsSticky: { true }
        )
        let panel = LauncherPanelController(core: core, aiIntegration: integration)

        panel.runAI(confirmation(action: "ai.ask", prompt: "who wrote the book 1984"))
        pump(until: {
            !panel.aiAnswerView.isHidden && panel.aiAnswerView.answer.contains("Sources")
        }, timeout: 45)
        let refined = panel.aiAnswerView.answer
        print("PROBE refined answer -> \(refined)")
        XCTAssertTrue(refined.contains("Sources"),
                      "local answer should be refined into a web-grounded answer with sources")
        panel.hide()
    }

    private func confirmation(action: String, prompt: String) -> LauncherConfirmation {
        LauncherConfirmation(
            actionName: action,
            result: SearchResult(id: "probe:\(action)", title: action, kind: .command,
                                 payload: ["prompt": .string(prompt)]),
            query: prompt,
            requiresUserConfirmation: false
        )
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval) {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
