import Foundation

extension SummonCore {
    public func snapshot(includeClipboard: Bool = true) throws -> CoreSnapshot {
        try dbQueue.read { db in
            CoreSnapshot(
                settings: try settings.all(in: db),
                snippets: try snippets.all(in: db),
                clipboard: includeClipboard ? try clipboard.snapshotItems(in: db) : [],
                quicklinks: try quicklinks.all(in: db)
            )
        }
    }

    func storeExportBundle(
        includeClipboard: Bool,
        exportedAt: Date = Date(),
        afterSnapshotStart: (() -> Void)? = nil
    ) throws -> StoreExportBundle {
        try dbQueue.read { db in
            let snapshotSettings = try settings.all(in: db)
            afterSnapshotStart?()
            let exportedFrecency = try frecency.all(in: db).filter {
                includeClipboard || $0.kind != SearchResult.Kind.clipboard.rawValue
            }
            let journalExport = try journal.exportRecords(in: db)
            let snapshot = CoreSnapshot(
                settings: snapshotSettings,
                snippets: try snippets.all(in: db),
                clipboard: includeClipboard ? try clipboard.snapshotItems(in: db) : [],
                quicklinks: try quicklinks.all(in: db)
            )
            return StoreExportBundle(
                exportedAt: exportedAt,
                snapshot: snapshot,
                aliases: try aliases.all(in: db),
                favorites: try favorites.all(in: db),
                clipboardIgnore: try clipboardIgnore.all(in: db),
                frecency: exportedFrecency,
                history: try history.all(in: db),
                stagedProposals: try staged.list(state: nil, in: db),
                journal: journalExport.records,
                journalTotalCount: journalExport.totalCount,
                includeClipboard: includeClipboard
            )
        }
    }

    public func exportJSON() throws -> Data {
        try snapshot().canonicalJSON()
    }

    /// Pure store rebuild: applies actions without re-journaling or re-running destructive guard.
    public func replay(entries: [JournalEntry]) throws {
        for entry in entries where entry.outcome == "applied" {
            switch entry.action {
            case .moduleRun, .extensionInstall, .extensionGrant, .ftsConsentGrant:
                continue
            default:
                break
            }
            try bus.applyForReplay(entry.action)
            synchronizeRuntimeState(
                after: ActionResult(envelopeID: entry.id, outcome: .applied),
                action: entry.action
            )
        }
    }

    public func replayedCopy() throws -> SummonCore {
        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: try journal.appliedEntries())
        return fresh
    }
}
