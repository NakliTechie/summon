import Foundation

/// Live App Intents surface scaffold (SP-15 / D1).
/// Enumerates apps as synthetic open intents until full AppIntents runtime lands.
public struct LiveAppIntentEnumerator: AppIntentEnumerating, Sendable {
    public init() {}

    public func enumerate() throws -> [AppIntentDescriptor] {
        var out: [AppIntentDescriptor] = []
        let roots = ["/System/Applications", "/Applications"]
        let fm = FileManager.default
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in items where name.hasSuffix(".app") {
                let base = (name as NSString).deletingPathExtension
                out.append(AppIntentDescriptor(
                    id: "appintent.\(base).open",
                    title: "Open \(base)",
                    bundleID: base,
                    abbreviation: String(base.prefix(3)).lowercased()
                ))
            }
            if out.count > 40 { break }
        }
        return Array(out.prefix(40))
    }
}
