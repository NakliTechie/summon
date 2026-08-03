import Foundation
import GRDB

/// Headless core: bus + stores + journal + SchemaGate. Zero AppKit.
public final class SummonCore: @unchecked Sendable {
    public let containerURL: URL?
    public let dbQueue: DatabaseQueue
    public let settings: SettingsStore
    public let journal: ActionJournal
    public let bus: ActionBus
    public let schemaGate: SchemaGate

    /// Open (or create) a core rooted at a container directory.
    public convenience init(containerURL: URL) throws {
        let dbQueue = try SummonDatabase.open(in: containerURL)
        self.init(dbQueue: dbQueue, containerURL: containerURL)
    }

    /// Default container under Application Support/Summon.
    public convenience init() throws {
        let url = try SummonDatabase.defaultContainerURL()
        try self.init(containerURL: url)
    }

    /// In-memory core for tests.
    public static func inMemory() throws -> SummonCore {
        let dbQueue = try SummonDatabase.openInMemory()
        return SummonCore(dbQueue: dbQueue, containerURL: nil)
    }

    public init(dbQueue: DatabaseQueue, containerURL: URL?) {
        self.dbQueue = dbQueue
        self.containerURL = containerURL
        self.settings = SettingsStore(dbQueue: dbQueue)
        self.journal = ActionJournal(dbQueue: dbQueue)
        self.bus = ActionBus(settings: settings, journal: journal)
        self.schemaGate = SchemaGate()
    }

    // MARK: - Dispatch doors

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        try bus.dispatch(envelope)
    }

    /// External payload door: SchemaGate then bus. Actor is supplied by the door, never the payload.
    @discardableResult
    public func dispatchExternal(
        _ data: Data,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionResult {
        let envelope = try schemaGate.envelope(from: data, actor: actor, id: id, timestamp: timestamp)
        return try bus.dispatch(envelope)
    }

    /// Convenience for in-process doors (CLI args, stub UI).
    @discardableResult
    public func dispatch(
        action: CoreAction,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionResult {
        let envelope = ActionEnvelope(id: id, actor: actor, timestamp: timestamp, action: action)
        return try bus.dispatch(envelope)
    }

    // MARK: - Snapshot / export

    public func snapshot() throws -> CoreSnapshot {
        CoreSnapshot(settings: try settings.all())
    }

    public func exportJSON() throws -> Data {
        try snapshot().canonicalJSON()
    }

    // MARK: - Replay (gate §8.2 / invariant 7–8)

    /// Replay applied journal entries into this (typically fresh) core.
    ///
    /// Replayed actions re-enter via the bus so they are re-journaled on the
    /// destination core. Source journal order is preserved.
    public func replay(entries: [JournalEntry]) throws {
        for entry in entries where entry.outcome == "applied" {
            // Preserve original id/actor/timestamp so the destination journal
            // is a faithful copy of what ran.
            _ = try bus.dispatch(entry.envelope)
        }
    }

    /// Open a fresh in-memory core and replay this core's applied journal into it.
    public func replayedCopy() throws -> SummonCore {
        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: try journal.appliedEntries())
        return fresh
    }
}

// MARK: - Version

public enum SummonVersion {
    public static let string = "0.1.0-spine"
}
