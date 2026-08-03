import Foundation
import SummonCore

/// `summon` CLI skeleton — agent face door onto the same action bus as the UI.
///
/// Off-by-default agent socket lands later; this binary is always available for
/// headless dispatch and for the C-spine end-to-end gate.
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
        case "run":
            // Reserved for module actions (e.g. window.arrange). Spine stub.
            fputs("error: run: no modules registered yet (spine)\n", stderr)
            exit(2)
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            printUsage()
            exit(2)
        }
    }

    static func settingsCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("error: settings requires subcommand (set|get|delete|list)\n", stderr)
            exit(2)
        }
        let core = try SummonCore()
        // CLI is the agent face for machine callers; human-driven CLI still tags agent
        // when used as the documented agent surface. Direct human UI uses actor=user.
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

    static func printUsage() {
        let usage = """
        summon \(SummonVersion.string) — sovereign macOS launcher (CLI skeleton)

        Usage:
          summon version
          summon settings set <key> <value>
          summon settings get <key>
          summon settings delete <key>
          summon settings list
          summon run <module.action> [flags]   (modules land after C-spine)

        Every mutating command dispatches the action bus and is journaled
        with actor=agent.
        """
        print(usage)
    }
}
