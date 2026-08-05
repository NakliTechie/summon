import Foundation
import SummonCore

extension SummonCLI {
    static func admitAgentCLIIfNeeded(_ args: [String]) throws {
        guard cliActor == .agent else { return }
        let core = try SummonCore()
        try CLIActorPolicy.authorizeAgentFace(
            actor: cliActor,
            enabledValue: try core.settings.get(AgentSocketServer.enabledSettingKey)
        )
        let action: CoreAction
        switch args.first {
        case "--version", "version", "-v":
            action = .agentVersion
        case "search":
            action = .agentSearch(
                query: args.dropFirst().joined(separator: " "),
                includedSensitive: try sensitiveReadAllowed(core)
            )
        default:
            action = .agentCLI(command: agentCLICommandPath(args))
        }
        let result = try core.dispatch(action: action, actor: .agent)
        guard result.isApplied else {
            throw CoreError.store("agent CLI audit event was not applied")
        }
    }

    private static func agentCLICommandPath(_ args: [String]) -> String {
        let knownCommands: Set<String> = [
            "help", "--help", "-h", "settings", "search", "calc", "snippet",
            "clipboard", "quicklink", "actions", "run", "ai", "web", "window",
            "latency", "fts", "export", "import", "alias", "favorite", "ignore",
            "guide",
        ]
        guard let first = args.first, knownCommands.contains(first) else { return "unknown" }
        let command = ["--help", "-h"].contains(first) ? "help" : first
        let subcommandFamilies: Set<String> = [
            "settings", "snippet", "clipboard", "quicklink", "ai", "web", "window",
            "fts", "alias", "favorite", "ignore",
        ]
        guard subcommandFamilies.contains(command), args.count > 1 else { return command }
        let subcommand = String(args[1].prefix(64))
        return "\(command).\(subcommand)"
    }

    static func sensitiveReadAllowed(_ core: SummonCore) throws -> Bool {
        if cliActor == .user { return true }
        return try core.settings.get(AgentSocketServer.sensitiveSearchGrantSettingKey) == .bool(true)
    }

    static func requireSensitiveReadGrant(_ core: SummonCore) throws {
        guard try sensitiveReadAllowed(core) else {
            throw CoreError.store(
                "agent sensitive-data read requires user grant \(AgentSocketServer.sensitiveSearchGrantSettingKey)"
            )
        }
    }

    static func requireUserOperation(_ operation: CLIPrivilegedOperation) throws {
        try CLIActorPolicy.authorize(actor: cliActor, operation: operation)
    }

    static func exitForOutcome(_ result: ActionResult) -> Never {
        switch result.outcome {
        case .applied:
            preconditionFailure("applied outcomes do not exit")
        case .staged(let proposalID):
            print("outcome staged proposalID=\(proposalID)")
            exit(3)
        case .rejected(let reason):
            fputs("outcome rejected reason=\(reason)\n", stderr)
            exit(1)
        }
    }

    static func cli_latencyCommand(_ args: [String]) throws {
        if args.first == "live" {
            try liveLatencyCommand(Array(args.dropFirst()))
            return
        }
        let iterations = boundedIterations(args.first, fallback: 100, maximum: 10_000)
        let core = try SummonCore.inMemory()
        let sample = try LatencyProbe.measure(label: "search-keystroke", iterations: iterations) {
            _ = try core.search.search("a")
        }
        let milliseconds = String(format: "%.3f", sample.milliseconds)
        print(
            "p95_ms=\(milliseconds) iterations=\(sample.iterations) "
                + "budget=\(LatencyProbe.keystrokeResultsMs)"
        )
        if !LatencyProbe.p95Passes(sample: sample, budgetMs: LatencyProbe.keystrokeResultsMs) {
            fputs("warn: exceeds keystroke budget \(LatencyProbe.keystrokeResultsMs)ms\n", stderr)
        }
    }

    private static func liveLatencyCommand(_ args: [String]) throws {
        let iterations = boundedIterations(args.first, fallback: 50, maximum: 1_000)
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory.appendingPathComponent(
            "summon-live-latency-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: container) }

        let core = try SummonCore(containerURL: container)
        for index in 0..<500 {
            _ = try core.ingestClipboard(
                text: "summon-latency-marker-\(index) invoice",
                types: ["public.utf8-plain-text"],
                sourceApp: "Summon latency gate",
                actor: .system
            )
        }

        let appQuery = try FilterGrammar.parse("a kind:app")
        let clipboardQuery = try FilterGrammar.parse("summon-latency-marker-499 kind:clipboard")
        _ = core.search.apps.scan()
        guard try core.clipboard.search(query: clipboardQuery, limit: 10).count == 1 else {
            throw CoreError.store("live latency store fixture was not queryable")
        }
        let storeSample = try LatencyProbe.measure(
            label: "live-app-and-500-row-store",
            iterations: iterations
        ) {
            _ = core.search.apps.search(query: appQuery, limit: 50)
            _ = try core.clipboard.search(query: clipboardQuery, limit: 50)
        }

        core.enableLiveSpotlight()
        let spotlightQuery = try FilterGrammar.parse("app kind:file")
        var spotlightCount = 0
        let spotlightSample = try LatencyProbe.measure(
            label: "live-spotlight",
            iterations: min(5, iterations)
        ) {
            spotlightCount = try core.search.spotlight.search(query: spotlightQuery, limit: 20).count
        }

        printSample(storeSample, budget: LatencyProbe.keystrokeResultsMs)
        printSample(spotlightSample, budget: LatencyProbe.liveSpotlightMs, count: spotlightCount)

        #if arch(arm64)
        guard LatencyProbe.p95Passes(
            sample: storeSample,
            budgetMs: LatencyProbe.keystrokeResultsMs
        ) else {
            throw CoreError.store(
                "live app/store p95 exceeds \(LatencyProbe.keystrokeResultsMs)ms arm64 budget"
            )
        }
        guard LatencyProbe.p95Passes(
            sample: spotlightSample,
            budgetMs: LatencyProbe.liveSpotlightMs
        ) else {
            throw CoreError.store(
                "live Spotlight p95 exceeds \(LatencyProbe.liveSpotlightMs)ms arm64 budget"
            )
        }
        print("latency-hard: arm64 budgets enforced")
        #else
        print("latency-hard: metrics recorded; arm64 enforcement unavailable on this architecture")
        #endif
    }

    private static func boundedIterations(
        _ raw: String?,
        fallback: Int,
        maximum: Int
    ) -> Int {
        min(max(Int(raw ?? "") ?? fallback, 1), maximum)
    }

    private static func printSample(
        _ sample: LatencySample,
        budget: Double,
        count: Int? = nil
    ) {
        let milliseconds = String(format: "%.3f", sample.milliseconds)
        let countField = count.map { " count=\($0)" } ?? ""
        print(
            "label=\(sample.label) p95_ms=\(milliseconds) iterations=\(sample.iterations)"
                + " budget=\(budget)\(countField)"
        )
    }
}
