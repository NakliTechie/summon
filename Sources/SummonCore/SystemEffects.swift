import Foundation

/// Maps summon://system/* to fixed local effects (no user shell strings).
public enum SystemEffects {
    public static func perform(url: String, executor: any ModuleExecuting) throws {
        if url.hasPrefix("summon://system/") {
            let action = String(url.dropFirst("summon://system/".count))
            switch action {
            case "sleep":
                try run("/usr/bin/pmset", ["sleepnow"])
            case "lock":
                let cg = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
                if FileManager.default.isExecutableFile(atPath: cg) {
                    try run(cg, ["-suspend"])
                } else {
                    try run("/usr/bin/pmset", ["displaysleepnow"])
                }
            case "empty-trash":
                try run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
            default:
                throw CoreError.unknownAction(action)
            }
            return
        }
        try executor.open(pathOrURL: url)
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CoreError.io("\(exe) failed: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            throw CoreError.io("\(exe) exited \(process.terminationStatus)")
        }
    }
}
