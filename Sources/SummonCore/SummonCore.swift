import Foundation
import GRDB

/// Headless core: bus + stores + journal + SchemaGate + search. Zero AppKit.
public final class SummonCore: @unchecked Sendable {
    public let containerURL: URL?
    public let dbQueue: DatabaseQueue
    public let settings: SettingsStore
    public let snippets: SnippetStore
    public let journal: ActionJournal
    public let bus: ActionBus
    public let schemaGate: SchemaGate
    public var search: SearchService

    public convenience init(containerURL: URL) throws {
        let dbQueue = try SummonDatabase.open(in: containerURL)
        self.init(dbQueue: dbQueue, containerURL: containerURL)
    }

    public convenience init() throws {
        let url = try SummonDatabase.defaultContainerURL()
        try self.init(containerURL: url)
    }

    public static func inMemory(
        spotlight: (any SpotlightIndexing)? = nil,
        appSearchPaths: [URL]? = nil
    ) throws -> SummonCore {
        let dbQueue = try SummonDatabase.openInMemory()
        return SummonCore(
            dbQueue: dbQueue,
            containerURL: nil,
            spotlight: spotlight,
            appSearchPaths: appSearchPaths
        )
    }

    public init(
        dbQueue: DatabaseQueue,
        containerURL: URL?,
        spotlight: (any SpotlightIndexing)? = nil,
        appSearchPaths: [URL]? = nil
    ) {
        self.dbQueue = dbQueue
        self.containerURL = containerURL
        self.settings = SettingsStore(dbQueue: dbQueue)
        self.snippets = SnippetStore(dbQueue: dbQueue)
        self.journal = ActionJournal(dbQueue: dbQueue)
        self.bus = ActionBus(settings: settings, snippets: snippets, journal: journal)
        self.schemaGate = SchemaGate()
        self.search = SearchService(
            apps: AppCatalog(searchPaths: appSearchPaths),
            spotlight: spotlight ?? FakeSpotlightIndex(),
            snippets: snippets
        )
    }

    /// Wire real mdfind S1 for production cores (not default in unit tests).
    public func enableLiveSpotlight() {
        search.spotlight = MdfindSpotlightIndex()
    }

    // MARK: - Dispatch doors

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        try bus.dispatch(envelope)
    }

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
        CoreSnapshot(settings: try settings.all(), snippets: try snippets.all())
    }

    public func exportJSON() throws -> Data {
        try snapshot().canonicalJSON()
    }

    // MARK: - Replay

    public func replay(entries: [JournalEntry]) throws {
        for entry in entries where entry.outcome == "applied" {
            _ = try bus.dispatch(entry.envelope)
        }
    }

    public func replayedCopy() throws -> SummonCore {
        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: try journal.appliedEntries())
        return fresh
    }
}

// MARK: - Version

public enum SummonVersion {
    public static let string = "0.2.0-c1"
}
