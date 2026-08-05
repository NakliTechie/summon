import Foundation
import SummonCore

extension SummonCLI {
    static func cli_ftsCommand(_ args: [String]) throws {
        let core = try makeCore()
        guard let sub = args.first else {
            fputs("usage: summon fts consent|enable|disable|index|search|status\n", stderr)
            exit(2)
        }
        switch sub {
        case "consent":
            try requireUserOperation(.ftsConsent)
            try core.grantFTSConsent(actor: cliActor)
            print("ok fts consent granted")
        case "enable":
            try requireUserOperation(.ftsConfiguration)
            try core.setFTSEnabled(true, actor: cliActor)
            print("fts enabled")
        case "disable":
            try requireUserOperation(.ftsConfiguration)
            try core.setFTSEnabled(false, actor: cliActor)
            print("fts disabled")
        case "status":
            try requireSensitiveReadGrant(core)
            print(
                "enabled=\(core.search.ftsEnabled) consent=\(core.ftsConsentGranted()) "
                    + "docs=\(try core.fts.count())"
            )
        case "index":
            try requireUserOperation(.ftsIndex)
            guard args.count >= 2 else {
                fputs("usage: summon fts index <file>\n", stderr)
                exit(2)
            }
            guard core.ftsConsentGranted() && core.search.ftsEnabled else {
                fputs("error: FTS consent required — run: summon fts consent && summon fts enable\n", stderr)
                exit(1)
            }
            let url = URL(fileURLWithPath: args[1])
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try core.fts.upsert(FTSDocument(
                id: url.path,
                title: url.lastPathComponent,
                body: body,
                path: url.path
            ))
            print("indexed \(url.path)")
        case "search":
            try requireSensitiveReadGrant(core)
            let query = args.dropFirst().joined(separator: " ")
            for doc in try core.fts.search(query: query) {
                print("\(doc.title)\t\(doc.path ?? "")")
            }
        default:
            fputs("usage: summon fts consent|enable|disable|index|search|status\n", stderr)
            exit(2)
        }
    }

    static func cli_exportCommand(_ args: [String]) throws {
        let core = try makeCore()
        try requireSensitiveReadGrant(core)
        let includeClipboard = args.contains("--include-clipboard")
        let data = try DataExport.export(core: core, includeClipboard: includeClipboard)
        if let path = args.first(where: { !$0.hasPrefix("--") }) {
            try requireUserOperation(.exportFile)
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } else if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func cli_importCommand(_ args: [String]) throws {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            fputs("usage: summon import <file.json> [--replace] [--include-clipboard]\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        try requireUserOperation(.importData)
        let data = try DataExport.readImportFile(at: URL(fileURLWithPath: path))
        try DataExport.importJSON(
            data,
            into: core,
            actor: cliActor,
            mode: args.contains("--replace") ? .replace : .merge,
            importClipboard: args.contains("--include-clipboard")
        )
        print("imported \(path)")
    }

    static func cli_aliasCommand(_ args: [String]) throws {
        let core = try makeCore()
        guard let sub = args.first else {
            fputs("usage: summon alias set|list|delete\n", stderr)
            exit(2)
        }
        switch sub {
        case "set":
            try requireUserOperation(.aliasMutation)
            guard args.count >= 4 else {
                fputs("usage: summon alias set <kw> <resultID> <title>\n", stderr)
                exit(2)
            }
            let resolved = try? core.search.search(
                args[3],
                limit: 50,
                includeSensitiveStores: try sensitiveReadAllowed(core)
            )
                .first { $0.id == args[2] }
            let result = try core.dispatch(
                action: .aliasSet(
                    keyword: args[1],
                    targetResultID: args[2],
                    title: args[3],
                    kind: args.count > 4 ? args[4] : (resolved?.kind.rawValue ?? "app"),
                    path: resolved?.path,
                    payload: resolved?.payload
                ),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        case "list":
            try requireSensitiveReadGrant(core)
            for alias in try core.aliases.all() {
                print("\(alias.keyword)\t\(alias.title)\t\(alias.targetResultID)")
            }
        case "delete":
            try requireUserOperation(.aliasMutation)
            guard args.count >= 2 else { exit(2) }
            let result = try core.dispatch(action: .aliasDelete(keyword: args[1]), actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        default:
            exit(2)
        }
    }

    static func cli_favoriteCommand(_ args: [String]) throws {
        let core = try makeCore()
        guard let sub = args.first else {
            fputs("usage: summon favorite add|list|remove\n", stderr)
            exit(2)
        }
        switch sub {
        case "add":
            try requireUserOperation(.favoriteMutation)
            guard args.count >= 3 else { exit(2) }
            let item = FavoriteItem(
                resultID: args[1],
                title: args[2],
                kind: args.count > 3 ? args[3] : "app"
            )
            let result = try core.dispatch(
                action: .favoriteAdd(
                    id: item.id,
                    resultID: item.resultID,
                    title: item.title,
                    kind: item.kind,
                    path: item.path
                ),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        case "list":
            try requireSensitiveReadGrant(core)
            for favorite in try core.favorites.all() {
                print("\(favorite.resultID)\t\(favorite.title)")
            }
        case "remove":
            try requireUserOperation(.favoriteMutation)
            guard args.count >= 2 else { exit(2) }
            let result = try core.dispatch(
                action: .favoriteRemove(resultID: args[1]),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        default:
            exit(2)
        }
    }

    static func cli_ignoreCommand(_ args: [String]) throws {
        let core = try makeCore()
        guard let sub = args.first else {
            fputs("usage: summon ignore add|list|remove\n", stderr)
            exit(2)
        }
        switch sub {
        case "add":
            guard args.count >= 2 else { exit(2) }
            let result = try core.dispatch(action: .clipboardIgnoreAdd(entry: args[1]), actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        case "list":
            try requireSensitiveReadGrant(core)
            for app in try core.clipboardIgnore.all() {
                print(app)
            }
        case "remove":
            guard args.count >= 2 else { exit(2) }
            let result = try core.dispatch(action: .clipboardIgnoreRemove(entry: args[1]), actor: cliActor)
            guard result.isApplied else { exitForOutcome(result) }
            print("ok")
        default:
            exit(2)
        }
    }
}
