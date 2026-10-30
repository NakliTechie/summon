import Foundation
import SummonCore

extension SummonCLI {
    static let filesUsage = "usage: summon files enable|disable|index|status|search <query> [--limit N] [--fresh]|bench <query>..."

    static func cli_filesCommand(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs(filesUsage + "\n", stderr)
            exit(2)
        }
        let core = try makeCore()
        switch sub {
        case "enable", "disable":
            try requireUserOperation(.fileIndex)
            let result = try core.dispatch(
                action: .settingsSet(key: FileIndexService.enabledSettingKey, value: .bool(sub == "enable")),
                actor: cliActor
            )
            guard result.isApplied else { exitForOutcome(result) }
            print("file index \(sub)d" + (sub == "enable" ? " (run `summon files index` to build it now)" : ""))
        case "index":
            try requireUserOperation(.fileIndex)
            let service = try core.makeFileIndexService()
            print("indexing \(service.roots.joined(separator: ", ")) …")
            let report = try service.build()
            print(String(
                format: "indexed %d entries (%d distinct names) in %.1f s → %@",
                report.entries, report.distinctNames, report.seconds, service.snapshotURL.path
            ))
            if !report.unreadable.isEmpty {
                print("unreadable folders: \(report.unreadable.count) (no permission; grant Full Disk Access to include them)")
                for path in report.unreadable.prefix(10) { print("  \(path)") }
            }
        case "status":
            let service = try core.fileIndexService ?? core.makeFileIndexService()
            if !service.isLoaded { _ = try? service.load() }
            let status = service.status()
            print("enabled=\(core.fileIndexEnabled) loaded=\(status.loaded) entries=\(status.entries) names=\(status.distinctNames)")
            print("roots: \(status.roots.joined(separator: ", "))")
            if let builtAt = status.builtAt { print("built: \(ISO8601DateFormatter().string(from: builtAt))") }
            if let bytes = status.snapshotBytes { print("snapshot: \(bytes / 1_048_576) MB at \(service.snapshotURL.path)") }
            print("excluded:")
            for line in status.exclusions { print("  \(line)") }
        case "search":
            var rest = Array(args.dropFirst())
            var limit = 20
            let fresh = rest.contains("--fresh")
            rest.removeAll { $0 == "--fresh" }
            if let i = rest.firstIndex(of: "--limit"), i + 1 < rest.count, let n = Int(rest[i + 1]) {
                limit = n
                rest.removeSubrange(i...(i + 1))
            }
            let raw = rest.joined(separator: " ")
            guard !raw.isEmpty else { fputs(filesUsage + "\n", stderr); exit(2) }
            let service = try loadedService(core, fresh: fresh)
            let query = (try? FilterGrammar.parse(raw)) ?? FilterQuery(freeText: raw, filters: [])
            let start = DispatchTime.now().uptimeNanoseconds
            let results = service.search(query: query, limit: limit) ?? []
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            for (i, r) in results.enumerated() { print("\(i + 1). \(r.subtitle ?? r.title)") }
            fputs(String(format: "%d results in %.2f ms\n", results.count, ms), stderr)
            if results.isEmpty { exit(1) }
        case "bench":
            try benchCommand(core, queries: Array(args.dropFirst()))
        default:
            fputs(filesUsage + "\n", stderr)
            exit(2)
        }
    }

    /// Loads the snapshot. `fresh` first replays FSEvents since it was written
    /// (about 4 s of FSEvents daemon time on a home folder) and saves the result;
    /// the app keeps its own copy live, so the CLI does not pay this by default.
    private static func loadedService(_ core: SummonCore, fresh: Bool = false, timings: Bool = false) throws -> FileIndexService {
        let service = try core.makeFileIndexService()
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ label: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            if timings { fputs(String(format: "  %@ %.0f ms\n", label, Double(now - mark) / 1e6), stderr) }
            mark = now
        }
        guard try service.load() else {
            throw CoreError.store("no file index for \(service.roots.joined(separator: ", ")); run `summon files index`")
        }
        lap("load")
        if fresh {
            service.catchUp(keepWatching: false, timeout: 20)
            lap("replay")
            try? service.saveIfDirty()
            lap("save")
        }
        return service
    }

    /// Observed, not a benchmark: the same queries against the index and
    /// against Spotlight (`mdfind`) on this Mac, with result counts beside times.
    private static func benchCommand(_ core: SummonCore, queries: [String]) throws {
        let defaults = ["main", "readme", "package.json", "mian", "invoice", "summon swift"]
        let list = queries.isEmpty ? defaults : queries
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let service = try loadedService(core, timings: true)
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1e6
        let status = service.status()
        print(String(format: "observed, not a benchmark — %d entries; snapshot load %.0f ms", status.entries, loadMs))
        print("query\tindex p50 ms\tindex hits\tspotlight ms\tspotlight hits")
        let spotlight = MdfindSpotlightIndex()
        for raw in list {
            let query = (try? FilterGrammar.parse(raw)) ?? FilterQuery(freeText: raw, filters: [])
            var times: [Double] = []
            var hits = 0
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                hits = service.search(query: query, limit: 500)?.count ?? 0
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            times.sort()
            let sStart = DispatchTime.now().uptimeNanoseconds
            let sHits = (try? spotlight.search(query: query, limit: 500).count) ?? 0
            let sMs = Double(DispatchTime.now().uptimeNanoseconds - sStart) / 1e6
            print(String(format: "%@\t%.2f\t%d\t%.1f\t%d", raw, times[times.count / 2], hits, sMs, sHits))
        }
    }
}
