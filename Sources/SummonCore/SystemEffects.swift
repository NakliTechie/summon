import Foundation

/// Maps summon://system/* to fixed local effects (no user shell strings).
public enum SystemEffects {
    public static func requiresUserConfirmation(url: String) -> Bool {
        url == "summon://system/empty-trash"
    }

    public static func perform(url: String, executor: any ModuleExecuting) throws {
        if url.hasPrefix("summon://system/") {
            let action = String(url.dropFirst("summon://system/".count))
            // Parameterized effect: set-volume/<0…100>. The only fixed local
            // effect that carries an argument; everything else is arg-less.
            if action.hasPrefix("set-volume/") {
                try setVolume(String(action.dropFirst("set-volume/".count)))
                return
            }
            switch action {
            case "sleep":
                try run("/usr/bin/pmset", ["sleepnow"])
            case "lock":
                let cg = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
                if FileManager.default.isExecutableFile(atPath: cg) {
                    try run(cg, ["-suspend"])
                } else {
                    throw CoreError.io("Lock Screen is unavailable on this macOS installation")
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

    private static func setVolume(_ raw: String) throws {
        guard let level = Int(raw), (0...100).contains(level) else {
            throw CoreError.store("set-volume requires an integer level 0–100")
        }
        // `set volume output volume` is a direct system AppleScript command — no
        // Automation (TCC) prompt, unlike scripting another app.
        try run("/usr/bin/osascript", ["-e", "set volume output volume \(level)"])
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
