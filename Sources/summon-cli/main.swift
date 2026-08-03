import Foundation
import SummonCore

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

        Mutating commands journal actor=agent.
        """)
    }
}
