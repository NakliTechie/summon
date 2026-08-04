import AppKit
import Foundation
import SummonCore

/// Live pasteboard watcher. Honors Maccy privacy types via PasteboardPrivacy.
/// Runs for process lifetime (resident capture) — panel need not be open.
public final class PasteboardService: @unchecked Sendable {
    private let core: SummonCore
    private var lastChangeCount: Int = -1
    private var timer: Timer?

    public init(core: SummonCore) {
        self.core = core
    }

    public func startPolling(interval: TimeInterval = 0.5) {
        stopPolling()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Common modes so capture continues during tracking / menu use.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Ingest whatever is currently on the pasteboard once at start (optional soft).
        // Skip initial dump to avoid re-logging huge clips on every launch — only new changes.
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Single poll — also used by tests with injected types.
    @discardableResult
    public func poll() -> Bool {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return false }
        lastChangeCount = count
        let types = pb.types?.map(\.rawValue) ?? []
        guard let text = pb.string(forType: .string), !text.isEmpty else { return false }
        do {
            let result = try core.ingestClipboard(
                text: text,
                types: types,
                sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                actor: .system
            )
            return result != nil
        } catch {
            return false
        }
    }

    @discardableResult
    public static func ingestIfAllowed(
        core: SummonCore,
        text: String,
        types: [String],
        sourceApp: String? = nil
    ) throws -> ActionResult? {
        try core.ingestClipboard(text: text, types: types, sourceApp: sourceApp, actor: .system)
    }
}
