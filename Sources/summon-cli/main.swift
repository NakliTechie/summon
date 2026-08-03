import Foundation
import SummonCore

/// `summon` CLI — agent face door onto the same action bus as the UI.
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
            printUsage()
            exit(2)
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
        return core
    }

    static func settingsCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: settings requires subcommand (set|get|delete|list)\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        let actor: ActorTag = .agent

        switch sub {
        case "set":
            guard args.count >= 3 else {
                fputs("usage: summon settings set <key> <value>\n", stderr)
                exit(2)
            }
            let key = args[1]
            let value = JSONValue.parseCLI(args[2])
            let result = try core.dispatch(
                action: .settingsSet(key: key, value: value),
                actor: actor
            )
            guard result.isApplied else {
                if case .rejected(let reason) = result.outcome {
                    fputs("error: \(reason)\n", stderr)
                }
                exit(1)
            }
            print("ok \(key)=\(value)")
        case "get":
            guard args.count >= 2 else {
                fputs("usage: summon settings get <key>\n", stderr)
                exit(2)
            }
            let key = args[1]
            if let value = try core.settings.get(key) {
                print(value)
            } else {
                exit(1)
            }
        case "delete":
            guard args.count >= 2 else {
                fputs("usage: summon settings delete <key>\n", stderr)
                exit(2)
            }
            let key = args[1]
            let result = try core.dispatch(
                action: .settingsDelete(key: key),
                actor: actor
            )
            guard result.isApplied else {
                exit(1)
            }
            print("ok deleted \(key)")
        case "list":
            let all = try core.settings.all()
            for key in all.keys.sorted() {
                if let value = all[key] {
                    print("\(key)=\(value)")
                }
            }
        default:
            fputs("error: unknown settings subcommand '\(sub)'\n", stderr)
            exit(2)
        }
    }

    static func searchCommand(_ args: [String]) throws {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else {
            fputs("usage: summon search <query>\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        let results = try core.search.search(query)
        for (index, result) in results.enumerated() {
            let sub = result.subtitle.map { " — \($0)" } ?? ""
            print("\(index + 1). [\(result.kind.rawValue)] \(result.title)\(sub)")
        }
        if results.isEmpty {
            exit(1)
        }
    }

    static func calcCommand(_ args: [String]) throws {
        let expr = args.joined(separator: " ")
        guard !expr.isEmpty else {
            fputs("usage: summon calc <expression>\n", stderr)
            exit(2)
        }
        guard let value = Calculator.evaluate(expr) else {
            fputs("error: not a calculable expression\n", stderr)
            exit(1)
        }
        print(Calculator.format(value))
    }

    static func snippetCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: snippet requires subcommand (add|list|delete)\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        let actor: ActorTag = .agent
        switch sub {
        case "add":
            guard args.count >= 3 else {
                fputs("usage: summon snippet add <name> <body> [keyword]\n", stderr)
                exit(2)
            }
            let name = args[1]
            let body = args[2]
            let keyword = args.count >= 4 ? args[3] : nil
            let id = UUID().uuidString
            let result = try core.dispatch(
                action: .snippetUpsert(id: id, name: name, body: body, keyword: keyword),
                actor: actor
            )
            guard result.isApplied else { exit(1) }
            print("ok \(id) \(name)")
        case "list":
            for snip in try core.snippets.all() {
                let kw = snip.keyword.map { " (\($0))" } ?? ""
                print("\(snip.id)\t\(snip.name)\(kw)")
            }
        case "delete":
            guard args.count >= 2 else {
                fputs("usage: summon snippet delete <id>\n", stderr)
                exit(2)
            }
            let result = try core.dispatch(
                action: .snippetDelete(id: args[1]),
                actor: actor
            )
            guard result.isApplied else { exit(1) }
            print("ok deleted \(args[1])")
        default:
            fputs("error: unknown snippet subcommand '\(sub)'\n", stderr)
            exit(2)
        }
    }

    static func actionsCommand(_ args: [String]) throws {
        guard let kindRaw = args.first, let kind = SearchResult.Kind(rawValue: kindRaw) else {
            fputs("usage: summon actions <app|file|folder|snippet|calculation|setting|command>\n", stderr)
            exit(2)
        }
        let result = SearchResult(id: "probe", title: "probe", kind: kind)
        for action in ObjectActionGrammar.actions(for: result) {
            print("\(action.name)\t\(action.title)\(action.isDestructive ? "\t[destructive]" : "")")
        }
    }

    static func runCommand(_ args: [String]) throws {
        guard let name = args.first else {
            fputs("usage: summon run <module.action> [args]\n", stderr)
            exit(2)
        }
        // C1: only journal that an agent requested the action; OS open lands with UI module.
        let core = try makeCore()
        let result = try core.dispatch(
            action: .settingsSet(key: "agent.lastRun", value: .string(name)),
            actor: .agent
        )
        guard result.isApplied else { exit(1) }
        print("ok staged \(name) (execution via UI/module handlers lands next)")
    }

    static func printUsage() {
        let usage = """
        summon \(SummonVersion.string) — sovereign macOS launcher (agent CLI)

        Usage:
          summon version
          summon search <query>
          summon calc <expression>
          summon actions <kind>
          summon settings set|get|delete|list …
          summon snippet add|list|delete …
          summon run <module.action>

        Search supports filter grammar: kind:pdf modified:<7d in:~/Documents
        Mutating commands journal actor=agent.
        """
        print(usage)
    }
}
