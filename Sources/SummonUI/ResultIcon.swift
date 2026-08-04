import AppKit
import SummonCore

/// Loads and caches result icons (apps via `NSWorkspace`, others via SF Symbols).
enum ResultIcon {
    private static let cache = NSCache<NSString, NSImage>()
    private static let iconPointSize = NSSize(width: 28, height: 28)

    static func image(for result: SearchResult) -> NSImage {
        if let path = result.path, !path.isEmpty {
            let key = path as NSString
            if let hit = cache.object(forKey: key) {
                return hit
            }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = iconPointSize
            cache.setObject(icon, forKey: key)
            return icon
        }
        return symbolFallback(for: result.kind)
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
        cache.setObject(configured, forKey: key)
        return configured
    }
}
