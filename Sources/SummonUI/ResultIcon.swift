import AppKit
import SummonCore

/// Loads and caches result icons (apps via `NSWorkspace`, others via SF Symbols).
enum ResultIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private static let iconPointSize = NSSize(width: 28, height: 28)

    static func image(for result: SearchResult) -> NSImage {
        if let path = result.path, !path.isEmpty {
            let key = path as NSString
            if let hit = cache.object(forKey: key) {
                return hit
            }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = iconPointSize
            cache.setObject(icon, forKey: key, cost: 28 * 28 * 4)
            return icon
        }
        return symbolFallback(for: result.kind)
    }

    static func preload(_ results: [SearchResult]) {
        for result in results where result.kind != .emoji {
            autoreleasepool { _ = image(for: result) }
        }
    }

    private static func symbolFallback(for kind: SearchResult.Kind) -> NSImage {
        let name: String
        switch kind {
        case .app: name = "app.fill"
        case .file: name = "doc"
        case .folder: name = "folder"
        case .snippet: name = "text.alignleft"
        case .calculation: name = "function"
        case .setting: name = "gearshape"
        case .command: name = "terminal"
        case .clipboard: name = "clipboard"
        case .quicklink: name = "link"
        case .emoji: name = "face.smiling"
        }
        let key = "sym:\(name)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: kind.rawValue)
            ?? NSImage(size: iconPointSize)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let configured = img.withSymbolConfiguration(config) ?? img
        configured.size = iconPointSize
        cache.setObject(configured, forKey: key, cost: 28 * 28 * 4)
        return configured
    }
}
