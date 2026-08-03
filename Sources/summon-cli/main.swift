import Foundation
import SummonCore
#if SUMMON_AI
import SummonAI
#endif

@main
struct SummonCLI {
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
        guard let command = args.first else {
            printUsage(); exit(2)
        }
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
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            printUsage()
            exit(2)
        }
    }

    static func makeCore() throws -> SummonCore {
        let core = try SummonCore()
        core.enableLiveSpotlight()
        // CLI open/reveal via /usr/bin/open; pasteboard via pbcopy for agent face.
        core.setExecutor(ProcessModuleExecutor { text in
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
        })
        return core
    }

    static func settingsCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: settings requires subcommand (set|get|delete|list)\n", stderr); exit(2)
        }
        let core = try makeCore()
        let actor: ActorTag = .agent
        switch sub {
        case "set":
            guard args.count >= 3 else { fputs("usage: summon settings set <key> <value>\n", stderr); exit(2) }
            let result = try core.dispatch(
                action: .settingsSet(key: args[1], value: JSONValue.parseCLI(args[2])),
                actor: actor
            )
            guard result.isApplied else { exit(1) }
            print("ok \(args[1])=\(args[2])")
        case "get":
            guard args.count >= 2 else { fputs("usage: summon settings get <key>\n", stderr); exit(2) }
            if let value = try core.settings.get(args[1]) { print(value) } else { exit(1) }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon settings delete <key>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .settingsDelete(key: args[1]), actor: actor)
            guard result.isApplied else { exit(1) }
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
        let results = try core.search.search(query)
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
        let actor: ActorTag = .agent
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
            guard result.isApplied else { exit(1) }
            print("ok \(id) \(args[1])")
        case "list":
            for snip in try core.snippets.all() {
                let kw = snip.keyword.map { " (\($0))" } ?? ""
                print("\(snip.id)\t\(snip.name)\(kw)")
            }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon snippet delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .snippetDelete(id: args[1]), actor: actor)
            guard result.isApplied else { exit(1) }
            print("ok deleted \(args[1])")
        default:
            fputs("error: unknown snippet subcommand '\(sub)'\n", stderr); exit(2)
        }
    }

    static func clipboardCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: clipboard requires subcommand (list|search|ingest|delete)\n", stderr); exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "list":
            for item in try core.clipboard.all(limit: 50) {
                let pin = item.isPinned ? "*" : " "
                let preview = item.text.replacingOccurrences(of: "\n", with: " ").prefix(60)
                print("\(pin) \(item.id)\t\(preview)")
            }
        case "search":
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
                actor: .agent
            )
            if result == nil {
                fputs("error: skipped by privacy gate\n", stderr); exit(1)
            }
            print("ok ingested")
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon clipboard delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .clipboardDelete(id: args[1]), actor: .agent)
            guard result.isApplied else { exit(1) }
            print("ok deleted \(args[1])")
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
                actor: .agent
            )
            guard result.isApplied else { exit(1) }
            print("ok \(id) \(args[1])")
        case "list":
            for link in try core.quicklinks.all() {
                print("\(link.id)\t\(link.name)\t\(link.url)")
            }
        case "delete":
            guard args.count >= 2 else { fputs("usage: summon quicklink delete <id>\n", stderr); exit(2) }
            let result = try core.dispatch(action: .quicklinkDelete(id: args[1]), actor: .agent)
            guard result.isApplied else { exit(1) }
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
        let outcome = try core.invoke(actionName: name, result: result, actor: .agent)
        guard outcome.isApplied else { exit(1) }
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
                try await service.completeAndStage(prompt: prompt, actor: .agent)
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
            let store = try FileL0WeightStore()
            let rung = L0PackagedModelRung.production(store: store)
            rung.grantConsent()
            print("ok L0 consent granted for \(rung.manifest.modelID) (MLX)")
            print("note: place model dir at ~/Library/Application Support/Summon/Models/\(rung.manifest.modelID)/")
            print("      or fetch HF repo \(rung.manifest.hfRepo)")
        case "parse-command":
            let text = args.dropFirst().joined(separator: " ")
            guard !text.isEmpty else {
                fputs("usage: summon ai parse-command <json-or-prose-with-json>\n", stderr)
                exit(2)
            }
            let parsed = try NLCommandSidecar.parse(output: text)
            print("ok \(parsed.actionName)")
        case "list-staged":
            try core.staged.migrate()
            for p in try core.staged.list(state: "staged") {
                print("\(p.id)\t\(p.rung)\t\(p.prompt.prefix(40))")
            }
        case "accept":
            guard args.count >= 2, let id = UUID(uuidString: args[1]) else {
                fputs("usage: summon ai accept <proposal-uuid>\n", stderr); exit(2)
            }
            if let p = try service.accept(id: id, actor: .agent) {
                print("accepted \(p.id)")
                print(p.output)
            } else {
                // Fall back to persisted store
                try core.staged.setState(id: args[1], state: "accepted")
                print("accepted \(args[1])")
            }
        case "reject":
            guard args.count >= 2, let id = UUID(uuidString: args[1]) else {
                fputs("usage: summon ai reject <proposal-uuid>\n", stderr); exit(2)
            }
            _ = try service.reject(id: id, actor: .agent)
            try? core.staged.setState(id: args[1], state: "rejected")
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

    static func webCommand(_ args: [String]) throws {
        #if SUMMON_AI
        guard let sub = args.first else {
            fputs("usage: summon web enable|disable|search <q> [--enrich]\n", stderr); exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "enable":
            core.webConfig.enableWithLocalhostPreset()
            try core.persistWebConfig()
            print("ok web enabled baseURL=\(core.webConfig.baseURL)")
        case "disable":
            core.webConfig.enabled = false
            try core.persistWebConfig()
            print("ok web disabled")
        case "search":
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
            let client = SearXNGClient(config: core.webConfig)
            let hits = try awaitOrRun { try await client.search(query: q) }
            if hits.isEmpty {
                print("(no hits)")
                exit(1)
            }
            print(WebEnrich.formatHitsOnly(hits))
            _ = try? core.dispatch(
                action: .settingsSet(
                    key: "web.lastEgressHost",
                    value: .string(URL(string: core.webConfig.baseURL)?.host ?? "unknown")
                ),
                actor: .agent
            )
            if enrich {
                let service = SummonAIService(core: core)
                let prompt = WebEnrich.enrichPrompt(question: q, hits: hits)
                let proposal = try awaitOrRun {
                    try await service.completeAndStage(prompt: prompt, actor: .agent)
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
            fputs("usage: summon window <leftHalf|rightHalf|maximize|...>\n", stderr); exit(2)
        }
        // Geometry always available; AX apply is UI-side (print frame for agent)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = WindowGeometry.frame(layout: layout, screen: screen, gap: 8)
        print("layout \(layout.rawValue)")
        print("frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        print("note: apply via Accessibility in summon-app (WindowApplicator)")
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
          summon version | search | calc | actions
          summon settings set|get|delete|list
          summon snippet add|list|delete
          summon clipboard list|search|ingest|delete
          summon quicklink add|list|delete
          summon run <module.action> <path>
          summon ai status | complete | accept | reject | l0-consent | list-staged
          summon web enable|disable|search <q> [--enrich]
          summon window <leftHalf|rightHalf|maximize|…>

        Mutating commands journal actor=agent.
        AI output is always staged (never auto-executed).
        Web search is opt-in (default OFF; enable presets localhost:8080).
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
