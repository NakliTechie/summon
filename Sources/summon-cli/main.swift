import Foundation
import SummonCore
import SummonUI
#if SUMMON_AI
import SummonAI
#endif

struct SummonCLI {
    /// Default `.user` for interactive CLI; set via `--actor agent` for automation.
    static var cliActor: ActorTag = .user

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try run(args: args)
        } catch let error as CoreError {
            fputs("error: \(error.message)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(args: [String]) throws {
        var args = args
        // Global: --actor user|agent (default user)
        if let idx = args.firstIndex(of: "--actor"), args.index(after: idx) < args.endIndex {
            let label = args[args.index(after: idx)]
            cliActor = try ActorTag(cliLabel: label)
            args.remove(at: args.index(after: idx))
            args.remove(at: idx)
        }
        guard let command = args.first else {
            printUsage(); exit(2)
        }
        try admitAgentCLIIfNeeded(args)
        switch command {
        case "--version", "version", "-v":
            print(SummonVersion.string)
        case "help", "--help", "-h":
            printUsage()
        case "settings":
            try settingsCommand(Array(args.dropFirst()))
        case "search":
            try searchCommand(Array(args.dropFirst()))
        case "calc":
            try calcCommand(Array(args.dropFirst()))
        case "snippet":
            try snippetCommand(Array(args.dropFirst()))
        case "clipboard":
            try clipboardCommand(Array(args.dropFirst()))
        case "quicklink":
            try quicklinkCommand(Array(args.dropFirst()))
        case "actions":
            try actionsCommand(Array(args.dropFirst()))
        case "run":
            try runCommand(Array(args.dropFirst()))
        case "ai":
            try aiCommand(Array(args.dropFirst()))
        case "web":
            try webCommand(Array(args.dropFirst()))
        case "window":
            try windowCommand(Array(args.dropFirst()))
        case "latency":
            try cli_latencyCommand(Array(args.dropFirst()))
        case "fts":
            try cli_ftsCommand(Array(args.dropFirst()))
        case "export":
            try cli_exportCommand(Array(args.dropFirst()))
        case "import":
            try cli_importCommand(Array(args.dropFirst()))
        case "alias":
            try cli_aliasCommand(Array(args.dropFirst()))
        case "favorite":
            try cli_favoriteCommand(Array(args.dropFirst()))
        case "ignore":
            try cli_ignoreCommand(Array(args.dropFirst()))
        case "guide":
            for r in GuideContent.searchResults() {
                print("\(r.title)\t\(r.subtitle ?? "")")
            }
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            printUsage()
            exit(2)
        }
    }

    static func makeCore() throws -> SummonCore {
        let core = try SummonCore()
        for warning in core.startupWarnings {
            fputs("warning: \(warning)\n", stderr)
        }
        core.enableLiveSpotlight()
        // CLI open/reveal via /usr/bin/open; pasteboard via pbcopy for agent face.
        core.setExecutor(ProcessModuleExecutor(
            pasteboardWriter: { text in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(Data(text.utf8))
                pipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    throw CoreError.io("pbcopy failed")
                }
            },
            windowArranger: { layout, gap in
                try WindowApplicator.apply(layout: layout, gap: gap)
            }
        ))
        return core
    }

    static func settingsCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: settings requires subcommand (set|get|delete|list)\n", stderr); exit(2)
        }
        let core = try makeCore()
        let actor: ActorTag = cliActor
        switch sub {
        case "set":
            guard args.count >= 3 else { fputs("usage: summon settings set <key> <value>\n", stderr); exit(2) }
            let result = try core.dispatch(
                action: .settingsSet(key: args[1], value: JSONValue.parseCLI(args[2])),
                actor: actor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok \(args[1])=\(args[2])")
        case "get":
            guard args.count >= 2 else { fputs("usage: summon settings get <key>\n", stderr); exit(2) }
            if let value = try core.settings.get(args[1]) { print(value) } else { exit(1) }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon settings delete <key>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .settingsDelete(key: args[1]), actor: actor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok deleted \(args[1])")
        case "list":
            for key in try core.settings.all().keys.sorted() {
                if let value = try core.settings.get(key) { print("\(key)=\(value)") }
            }
        default:
            fputs("error: unknown settings subcommand '\(sub)'\n", stderr); exit(2)
        }
    }

    static func searchCommand(_ args: [String]) throws {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { fputs("usage: summon search <query>\n", stderr); exit(2) }
        let core = try makeCore()
        let results = try core.search.search(
            query,
            includeSensitiveStores: try sensitiveReadAllowed(core)
        )
        for (index, result) in results.enumerated() {
            let sub = result.subtitle.map { " — \($0)" } ?? ""
            print("\(index + 1). [\(result.kind.rawValue)] \(result.title)\(sub)")
        }
        if results.isEmpty { exit(1) }
    }

    static func calcCommand(_ args: [String]) throws {
        let expr = args.joined(separator: " ")
        guard !expr.isEmpty else { fputs("usage: summon calc <expression>\n", stderr); exit(2) }
        guard let value = Calculator.evaluate(expr) else {
            fputs("error: not a calculable expression\n", stderr); exit(1)
        }
        print(Calculator.format(value))
    }

    static func snippetCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: snippet requires subcommand (add|list|delete)\n", stderr); exit(2)
        }
        let core = try makeCore()
        let actor: ActorTag = cliActor
        switch sub {
        case "add":
            guard args.count >= 3 else {
                fputs("usage: summon snippet add <name> <body> [keyword]\n", stderr); exit(2)
            }
            let id = UUID().uuidString
            let result = try core.dispatch(
                action: .snippetUpsert(
                    id: id, name: args[1], body: args[2],
                    keyword: args.count >= 4 ? args[3] : nil
                ),
                actor: actor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok \(id) \(args[1])")
        case "list":
            try requireSensitiveReadGrant(core)
            for snip in try core.snippets.all() {
                let kw = snip.keyword.map { " (\($0))" } ?? ""
                print("\(snip.id)\t\(snip.name)\(kw)")
            }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon snippet delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .snippetDelete(id: args[1]), actor: actor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok deleted \(args[1])")
        default:
            fputs("error: unknown snippet subcommand '\(sub)'\n", stderr); exit(2)
        }
    }

    static func clipboardCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: clipboard requires subcommand (list|search|ingest|delete|pin)\n", stderr); exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "list":
            try requireSensitiveReadGrant(core)
            for item in try core.clipboard.metadataPage(perBucketLimit: 25) {
                let pin = item.isPinned ? "*" : " "
                let preview = item.text.replacingOccurrences(of: "\n", with: " ").prefix(60)
                print("\(pin) \(item.id)\t\(preview)")
            }
        case "search":
            try requireSensitiveReadGrant(core)
            let q = args.dropFirst().joined(separator: " ")
            let results = try core.search.search(q.isEmpty ? "kind:clipboard" : "\(q) kind:clipboard")
            for r in results { print("\(r.title)") }
        case "ingest":
            // Agent/test door: plain text only; types default to public.utf8-plain-text.
            guard args.count >= 2 else {
                fputs("usage: summon clipboard ingest <text>\n", stderr); exit(2)
            }
            let text = args.dropFirst().joined(separator: " ")
            let result = try core.ingestClipboard(
                text: text,
                types: ["public.utf8-plain-text"],
                sourceApp: "summon-cli",
                actor: cliActor
            )
            if result == nil {
                fputs("error: skipped by privacy gate\n", stderr); exit(1)
            }
            print("ok ingested")
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon clipboard delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .clipboardDelete(id: args[1]), actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok deleted \(args[1])")
        case "pin":
            guard args.count >= 2 else {
                fputs("usage: summon clipboard pin <id> [on|off]\n", stderr); exit(2)
            }
            let pinned: Bool
            switch args.count >= 3 ? args[2].lowercased() : "on" {
            case "on", "true", "1": pinned = true
            case "off", "false", "0": pinned = false
            default:
                fputs("usage: summon clipboard pin <id> [on|off]\n", stderr); exit(2)
            }
            let result = try core.dispatch(
                action: .clipboardPin(id: args[1], pinned: pinned),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok \(pinned ? "pinned" : "unpinned") \(args[1])")
        default:
            fputs("error: unknown clipboard subcommand '\(sub)'\n", stderr); exit(2)
        }
    }

    static func quicklinkCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: quicklink requires subcommand (add|list|delete)\n", stderr); exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "add":
            guard args.count >= 3 else {
                fputs("usage: summon quicklink add <name> <url> [keyword]\n", stderr); exit(2)
            }
            let id = UUID().uuidString
            let result = try core.dispatch(
                action: .quicklinkUpsert(
                    id: id, name: args[1], url: args[2],
                    keyword: args.count >= 4 ? args[3] : nil
                ),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok \(id) \(args[1])")
        case "list":
            for link in try core.quicklinks.all() {
                print("\(link.id)\t\(link.name)\t\(link.url)")
            }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon quicklink delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .quicklinkDelete(id: args[1]), actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok deleted \(args[1])")
        default:
            fputs("error: unknown quicklink subcommand '\(sub)'\n", stderr); exit(2)
        }
    }

    static func actionsCommand(_ args: [String]) throws {
        guard let kindRaw = args.first, let kind = SearchResult.Kind(rawValue: kindRaw) else {
            fputs("usage: summon actions <kind>\n", stderr); exit(2)
        }
        let result = SearchResult(id: "probe", title: "probe", kind: kind)
        for action in ObjectActionGrammar.actions(for: result) {
            print("\(action.name)\t\(action.title)\(action.isDestructive ? "\t[destructive]" : "")")
        }
    }

    static func runCommand(_ args: [String]) throws {
        guard args.count >= 2 else {
            fputs("usage: summon run <module.action> <path-or-id>\n", stderr); exit(2)
        }
        let name = args[0]
        let target = args[1]
        let core = try makeCore()
        let result = SearchResult(
            id: target,
            title: target,
            kind: target.hasPrefix("/") ? .file : .app,
            path: target
        )
        let outcome = try core.invoke(actionName: name, result: result, actor: cliActor)
        guard outcome.isApplied else { exitForOutcome(outcome) }
        print("ok \(name) \(target)")
    }

    static func aiCommand(_ args: [String]) throws {
        #if SUMMON_AI
        guard let sub = args.first else {
            fputs("usage: summon ai status|complete <prompt>\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        let service = SummonAIService(core: core)
        switch sub {
        case "status":
            let rows = try awaitOrRun { await service.ladder.status() }
            for row in rows {
                let mark = row.available ? "on " : "off"
                print("\(mark)  \(row.id.rawValue)\t\(row.displayName)\t\(row.detail)")
            }
        case "complete":
            let prompt = args.dropFirst().joined(separator: " ")
            guard !prompt.isEmpty else {
                fputs("usage: summon ai complete <prompt>\n", stderr)
                exit(2)
            }
            let proposal = try awaitOrRun {
                try await service.completeAndStage(prompt: prompt, actor: cliActor)
            }
            print("staged \(proposal.id.uuidString)")
            print("rung \(proposal.rung.rawValue)")
            if !proposal.egressSummary.isEmpty {
                print("egress \(proposal.egressSummary)")
            }
            print("---")
            print(proposal.output)
            print("---")
            print("state \(proposal.state.rawValue) (not executed — accept in UI later)")
        case "l0-consent":
            try requireUserOperation(.modelConsent)
            let store = try FileL0WeightStore()
            let rung = L0PackagedModelRung.production(store: store)
            let priorConsent = store.consent()
            do {
                try rung.grantConsent()
                let result = try core.dispatch(
                    action: .modelConsentGrant(modelID: rung.manifest.modelID),
                    actor: cliActor
                )
                guard result.isApplied else {
                    throw CoreError.store("model consent audit was not applied: \(result.outcome)")
                }
            } catch {
                do {
                    try store.setConsent(priorConsent)
                } catch let rollbackError {
                    throw CoreError.store(
                        "model consent audit failed: \(error.localizedDescription); "
                            + "consent rollback failed: \(rollbackError.localizedDescription)"
                    )
                }
                throw error
            }
            print("ok experimental L0 consent granted for \(rung.manifest.modelID) (user-managed MLX)")
            print("note: summon ai l0-fetch downloads revision \(rung.manifest.hfRevision)")
        case "l0-fetch":
            try fetchL0Model(core: core)
        case "parse-command":
            let text = args.dropFirst().joined(separator: " ")
            guard !text.isEmpty else {
                fputs("usage: summon ai parse-command <json-or-prose-with-json>\n", stderr)
                exit(2)
            }
            let parsed = try NLCommandSidecar.parse(output: text)
            print("ok \(parsed.actionName)")
        case "list-staged":
            try requireSensitiveReadGrant(core)
            try core.staged.migrate()
            for p in try core.staged.list(state: "staged") {
                print("\(p.id)\t\(p.rung)\t\(p.prompt.prefix(40))")
            }
        case "accept":
            guard args.count >= 2, UUID(uuidString: args[1]) != nil else {
                fputs("usage: summon ai accept <proposal-uuid>\n", stderr); exit(2)
            }
            try requireUserOperation(.proposalDecision)
            guard let persisted = try core.staged.get(args[1]) else {
                throw CoreError.store("proposal \(args[1]) does not exist")
            }
            guard persisted.rung != "agent" else {
                throw CoreError.store("agent actions can only be accepted in Summon UI")
            }
            try core.acceptStagedTextProposal(
                id: args[1],
                reviewedOutput: persisted.output,
                actor: cliActor
            )
            print("accepted \(args[1])")
            print(persisted.output)
        case "reject":
            guard args.count >= 2, UUID(uuidString: args[1]) != nil else {
                fputs("usage: summon ai reject <proposal-uuid>\n", stderr); exit(2)
            }
            try requireUserOperation(.proposalDecision)
            guard let persisted = try core.staged.get(args[1]) else {
                throw CoreError.store("proposal \(args[1]) does not exist")
            }
            guard persisted.rung != "agent" else {
                throw CoreError.store("agent actions can only be rejected in Summon UI")
            }
            try core.rejectStagedProposal(id: args[1], actor: cliActor)
            print("rejected \(args[1])")
        default:
            fputs("error: unknown ai subcommand '\(sub)'\n", stderr)
            exit(2)
        }
        #else
        fputs("error: AI target compiled out (SUMMON_AI_ENABLED=0)\n", stderr)
        exit(1)
        #endif
    }

    #if SUMMON_AI
    private static func fetchL0Model(core: SummonCore) throws {
        try requireUserOperation(.modelFetch)
        let store = try FileL0WeightStore()
        let rung = L0PackagedModelRung.production(store: store)
        guard store.consent().granted else {
            fputs("error: consent required — run: summon ai l0-consent\n", stderr)
            exit(1)
        }
        do {
            let providerURL = URL(string: "https://huggingface.co/\(rung.manifest.hfRepo)")!
            let intent = try core.dispatch(
                action: .egressRequested(
                    purpose: EgressPurpose.userModelFetch.rawValue,
                    host: (providerURL.host ?? "huggingface.co").lowercased()
                ),
                actor: cliActor
            )
            guard let journalEntry = try core.journal.entry(id: intent.envelopeID) else {
                throw CoreError.journal("model-fetch egress intent missing after dispatch")
            }
            let authorization = try NetworkSovereignty.authorize(
                url: providerURL,
                purpose: .userModelFetch,
                actor: cliActor,
                journalEntry: journalEntry
            )
            let url = try L0ModelFetch.fetch(
                rung: rung,
                store: store,
                authorization: authorization
            )
            print("ok fetched \(url.path)")
            if let receipt = L0ModelFetch.readReceipt(modelDir: url) {
                print("revision \(receipt.hfRevision)")
                print("artifacts \(receipt.artifacts.count)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            fputs(
                "hint: L0 needs a supported user-managed mlx_lm.generate; Summon never installs it\n",
                stderr
            )
            exit(1)
        }
    }
    #endif

    static func webCommand(_ args: [String]) throws {
        #if SUMMON_AI
        guard let sub = args.first else {
            fputs("usage: summon web enable|disable|search <q> [--enrich]\n", stderr); exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "enable":
            core.webConfig.enableWithLocalhostPreset()
            let result = try core.persistWebConfig(actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok web enabled baseURL=\(core.webConfig.baseURL)")
        case "disable":
            core.webConfig.enabled = false
            let result = try core.persistWebConfig(actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok web disabled")
        case "search":
            try requireUserOperation(.webSearch)
            var enrich = false
            var qParts: [String] = []
            for a in args.dropFirst() {
                if a == "--enrich" { enrich = true } else { qParts.append(a) }
            }
            let q = qParts.joined(separator: " ")
            guard !q.isEmpty else { fputs("usage: summon web search <query> [--enrich]\n", stderr); exit(2) }
            guard core.webConfig.enabled else {
                fputs("error: web search off — run: summon web enable\n", stderr); exit(1)
            }
            guard let providerURL = URL(string: core.webConfig.baseURL),
                  let providerHost = providerURL.host else {
                throw CoreError.store("web search requires a valid provider URL")
            }
            let intent = try core.dispatch(
                action: .egressRequested(
                    purpose: EgressPurpose.userWeb.rawValue,
                    host: providerHost.lowercased()
                ),
                actor: cliActor
            )
            guard let journalEntry = try core.journal.entry(id: intent.envelopeID) else {
                throw CoreError.journal("web egress intent missing after dispatch")
            }
            let authorization = try NetworkSovereignty.authorize(
                url: providerURL,
                purpose: .userWeb,
                actor: cliActor,
                journalEntry: journalEntry
            )
            let client = SearXNGClient(config: core.webConfig)
            let hits = try awaitOrRun {
                try await client.search(query: q, authorization: authorization)
            }
            if hits.isEmpty {
                print("(no hits)")
                exit(1)
            }
            print(WebEnrich.formatHitsOnly(hits))
            if enrich {
                let service = SummonAIService(core: core)
                let prompt = WebEnrich.enrichPrompt(question: q, hits: hits)
                let proposal = try awaitOrRun {
                    try await service.completeAndStage(prompt: prompt, actor: cliActor)
                }
                print("---")
                print("staged enrich \(proposal.id.uuidString) rung=\(proposal.rung.rawValue)")
                print(proposal.output)
            }
        default:
            fputs("error: unknown web subcommand\n", stderr); exit(2)
        }
        #else
        fputs("error: AI/web compiled out\n", stderr); exit(1)
        #endif
    }

    static func windowCommand(_ args: [String]) throws {
        guard let layoutRaw = args.first, let layout = WindowLayout(rawValue: layoutRaw) else {
            fputs("usage: summon window <leftHalf|rightHalf|maximize|...> [--apply]\n", stderr); exit(2)
        }
        let apply = args.contains("--apply")
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = WindowGeometry.frame(layout: layout, screen: screen, gap: 8)
        print("layout \(layout.rawValue)")
        print("frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        if apply {
            let core = try makeCore()
            let result = try core.dispatch(
                action: .moduleRun(
                    name: "window.arrange",
                    targetID: "window:\(layout.rawValue)",
                    path: nil,
                    payload: ["layout": .string(layout.rawValue), "gap": .number(8)]
                ),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("applied via Accessibility")
        } else {
            print("note: pass --apply to set frontmost window (requires Accessibility)")
        }
    }

    /// Bridge async AI calls into the sync CLI entrypoint.
    static func awaitOrRun<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ConcurrentBox<Result<T, Error>>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                box.value = .success(try await body())
            } catch {
                box.value = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch box.value! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    static func printUsage() {
        print("""
        summon \(SummonVersion.string) — sovereign macOS launcher (agent CLI)

        Usage:
          summon version | search | calc | actions | guide | latency [n] | latency live [n]
          summon settings set|get|delete|list
          summon snippet add|list|delete
          summon clipboard list|search|ingest|delete|pin <id> [on|off]
          summon quicklink add|list|delete
          summon run <module.action> <path>
          summon ai status | complete | accept | reject | l0-consent | l0-fetch | list-staged | parse-command
          summon web enable|disable|search <q> [--enrich]
          summon window <leftHalf|rightHalf|maximize|…>
          summon fts consent|enable|disable|index|search|status
          summon export [file] | import <file>
          summon alias set|list|delete
          summon favorite add|list|remove
          summon ignore add|list|remove
        Mutating commands journal actor=user by default; pass --actor agent for automation.
        AI output is always staged (never auto-executed).
        Web search is opt-in (default OFF; enable presets localhost:8080).
        Binary name: summon-cli (SPM); user-facing brand is Summon.
        """)
    }

}

/// Simple thread-safe box for CLI async bridge.
private final class ConcurrentBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
SummonCLI.main()
