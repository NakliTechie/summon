import AppKit
import Foundation
import SummonCore

/// Live pasteboard watcher. Honors Maccy privacy types via PasteboardPrivacy.
/// Runs for process lifetime (resident capture) — panel need not be open.
public final class PasteboardService: @unchecked Sendable {
    public static let generatedType = NSPasteboard.PasteboardType("com.summon.clipboard.generated")
    public static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private let core: SummonCore
    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private let intakeQueue: DispatchQueue
    private let intakeLock = NSLock()
    private var pendingChange: PendingChange?
    private var intakeWorkerActive = false
    private let onProcessed: (@Sendable (Bool) -> Void)?
    private static let richTypes = PasteboardPrivacy.richTextTypes
    private static let imageTypes = PasteboardPrivacy.imageTypes

    public init(core: SummonCore) {
        self.core = core
        self.intakeQueue = DispatchQueue(label: "summon.clipboard.intake", qos: .utility)
        self.onProcessed = nil
    }

    init(
        core: SummonCore,
        intakeQueue: DispatchQueue,
        onProcessed: @escaping @Sendable (Bool) -> Void
    ) {
        self.core = core
        self.intakeQueue = intakeQueue
        self.onProcessed = onProcessed
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

    /// Single poll. It snapshots cheap metadata and schedules payload work.
    @discardableResult
    public func poll() -> Bool {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return false }
        lastChangeCount = count
        let types = pb.types?.map(\.rawValue) ?? []
        guard !PasteboardPrivacy.shouldSkip(types: types) else { return false }
        let declaredBundleID = pb.string(forType: Self.sourceType)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let observedBundleID = frontmost?.bundleIdentifier
        let observedApp = frontmost?.localizedName
        let sourceBundleID = declaredBundleID ?? frontmost?.bundleIdentifier
        let sourceApp = sourceBundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        } ?? frontmost?.localizedName
        enqueue(
            PendingChange(
                pasteboard: pb,
                changeCount: count,
                types: types,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID,
                observedSourceApp: observedApp,
                observedSourceBundleID: observedBundleID
            )
        )
        return true
    }

    /// Test seam for the live intake path without consulting the active application.
    @discardableResult
    func poll(
        pasteboard: NSPasteboard,
        sourceApp: String? = nil,
        sourceBundleID: String? = nil,
        observedSourceApp: String? = nil,
        observedSourceBundleID: String? = nil
    ) -> Bool {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return false }
        lastChangeCount = count
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !PasteboardPrivacy.shouldSkip(types: types) else { return false }
        enqueue(
            PendingChange(
                pasteboard: pasteboard,
                changeCount: count,
                types: types,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID,
                observedSourceApp: observedSourceApp,
                observedSourceBundleID: observedSourceBundleID
            )
        )
        return true
    }

    private func enqueue(_ change: PendingChange) {
        intakeLock.lock()
        pendingChange = change
        let startWorker = !intakeWorkerActive
        if startWorker {
            intakeWorkerActive = true
        }
        intakeLock.unlock()
        guard startWorker else { return }
        intakeQueue.async { [weak self] in
            self?.drainPendingChanges()
        }
    }

    private func drainPendingChanges() {
        while true {
            intakeLock.lock()
            guard let change = pendingChange else {
                intakeWorkerActive = false
                intakeLock.unlock()
                return
            }
            pendingChange = nil
            intakeLock.unlock()
            let processed = autoreleasepool {
                process(change)
            }
            onProcessed?(processed)
        }
    }

    private func process(_ change: PendingChange) -> Bool {
        guard change.pasteboard.changeCount == change.changeCount else { return false }
        guard let item = Self.item(
            from: change.pasteboard,
            types: change.types,
            sourceApp: change.sourceApp
        ) else { return false }
        do {
            let result = try core.ingestClipboard(
                item: item,
                types: change.types,
                sourceApp: change.sourceApp,
                sourceBundleID: change.sourceBundleID,
                observedSourceApp: change.observedSourceApp,
                observedSourceBundleID: change.observedSourceBundleID,
                actor: .system
            )
            return result != nil
        } catch {
            return false
        }
    }

    private struct PendingChange: @unchecked Sendable {
        let pasteboard: NSPasteboard
        let changeCount: Int
        let types: [String]
        let sourceApp: String?
        let sourceBundleID: String?
        let observedSourceApp: String?
        let observedSourceBundleID: String?
    }

    public static func writeGeneratedText(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) throws {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, generatedType], owner: nil)
        guard pasteboard.setString(text, forType: .string),
              pasteboard.setData(Data(), forType: generatedType) else {
            throw CoreError.io("pasteboard rejected generated text")
        }
    }

    public static func writeGeneratedItem(
        _ item: ClipboardItem,
        asPlainText: Bool,
        to pasteboard: NSPasteboard = .general
    ) throws {
        if asPlainText || item.contentKind == .plainText {
            try writeGeneratedText(item.plainText, to: pasteboard)
            return
        }

        switch item.contentKind {
        case .plainText:
            try writeGeneratedText(item.plainText, to: pasteboard)
        case .richText:
            guard let flavor = item.flavor, let data = item.data else {
                try writeGeneratedText(item.plainText, to: pasteboard)
                return
            }
            let richType = NSPasteboard.PasteboardType(flavor)
            pasteboard.clearContents()
            pasteboard.declareTypes([richType, .string, generatedType], owner: nil)
            guard pasteboard.setData(data, forType: richType),
                  pasteboard.setString(item.plainText, forType: .string),
                  pasteboard.setData(Data(), forType: generatedType) else {
                throw CoreError.io("pasteboard rejected generated rich text")
            }
        case .image:
            guard let flavor = item.flavor, let data = item.data else {
                throw CoreError.io("generated image is incomplete")
            }
            let imageType = NSPasteboard.PasteboardType(flavor)
            let tiff = flavor == NSPasteboard.PasteboardType.tiff.rawValue
                ? nil
                : NSImage(data: data)?.tiffRepresentation
            var types = [imageType]
            if tiff != nil { types.append(.tiff) }
            types.append(generatedType)
            pasteboard.clearContents()
            pasteboard.declareTypes(types, owner: nil)
            guard pasteboard.setData(data, forType: imageType) else {
                throw CoreError.io("pasteboard rejected generated image")
            }
            if let tiff, !pasteboard.setData(tiff, forType: .tiff) {
                throw CoreError.io("pasteboard rejected generated TIFF fallback")
            }
            guard pasteboard.setData(Data(), forType: generatedType) else {
                throw CoreError.io("pasteboard rejected generated marker")
            }
        case .file:
            pasteboard.clearContents()
            pasteboard.declareTypes([.fileURL, .string, generatedType], owner: nil)
            let urlString = item.data.flatMap { String(data: $0, encoding: .utf8) }
                ?? URL(fileURLWithPath: item.text).absoluteString
            guard pasteboard.setString(urlString, forType: .fileURL),
                  pasteboard.setString(item.text, forType: .string),
                  pasteboard.setData(Data(), forType: generatedType) else {
                throw CoreError.io("pasteboard rejected generated file")
            }
        }
    }

    static func item(
        from pasteboard: NSPasteboard,
        types: [String],
        sourceApp: String? = nil
    ) -> ClipboardItem? {
        guard !PasteboardPrivacy.shouldSkip(types: types) else { return nil }
        // File copy (Finder): capture the path + URL so it re-pastes as a file, not text.
        if types.contains(where: PasteboardPrivacy.fileTypes.contains),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL {
            return ClipboardItem(
                text: url.path,
                sourceApp: sourceApp,
                contentKind: .file,
                flavor: "public.file-url",
                data: Data(url.absoluteString.utf8)
            )
        }
        if let flavor = types.first(where: imageTypes.contains),
           let data = pasteboard.data(forType: NSPasteboard.PasteboardType(flavor)),
           !data.isEmpty {
            return ClipboardItem(
                text: "",
                sourceApp: sourceApp,
                contentKind: .image,
                flavor: flavor,
                data: data
            )
        }
        if let flavor = types.first(where: richTypes.contains),
           let data = pasteboard.data(forType: NSPasteboard.PasteboardType(flavor)),
           !data.isEmpty,
           let text = plainText(from: pasteboard, flavor: flavor, data: data),
           !text.isEmpty {
            return ClipboardItem(
                text: text,
                sourceApp: sourceApp,
                contentKind: .richText,
                flavor: flavor,
                data: data
            )
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return ClipboardItem(text: text, sourceApp: sourceApp)
    }

    private static func plainText(
        from pasteboard: NSPasteboard,
        flavor: String,
        data: Data
    ) -> String? {
        if let declared = pasteboard.string(forType: .string), !declared.isEmpty {
            return declared
        }
        let documentType: NSAttributedString.DocumentType = flavor == "public.html" ? .html : .rtf
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ).string
    }
}
