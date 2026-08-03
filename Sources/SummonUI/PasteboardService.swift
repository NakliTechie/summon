import AppKit
import Foundation
import SummonCore

/// Live pasteboard watcher + writer. Honors Maccy privacy types via PasteboardPrivacy.
public final class PasteboardService: @unchecked Sendable {
    private let core: SummonCore
    private var lastChangeCount: Int = -1
    private var timer: Timer?

    public init(core: SummonCore) {
        self.core = core
        // Wire pasteboard writer for module copy actions.
        core.setExecutor(
            ProcessModuleExecutor { text in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        )
    }

    public func startPolling(interval: TimeInterval = 0.5) {
        stopPolling()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        self.timer = timer
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

    /// Test/helper: evaluate privacy + ingest without reading the real pasteboard.
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
