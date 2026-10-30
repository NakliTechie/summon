import Foundation

/// The Swift file-name index as the launcher's file source. Off by default:
/// with `search.files.index.enabled` unset, files come from Spotlight as before.
extension SummonCore {
    public var fileIndexEnabled: Bool {
        (try? settings.get(FileIndexService.enabledSettingKey)) == .bool(true)
    }

    /// The service behind the current file source, when the index is in use.
    public var fileIndexService: FileIndexService? {
        (search.spotlight as? IndexedFileSearch)?.service
    }

    public func makeFileIndexService() throws -> FileIndexService {
        let container = try containerURL ?? SummonDatabase.defaultContainerURL()
        return FileIndexService.standard(container: container)
    }

    /// Switches file search to the index when the setting is on. The snapshot
    /// loads synchronously (tens of ms) and answers at once.
    ///
    /// With `watch` (the app), FSEvents replays the changes since the snapshot in
    /// the background, then keeps the index live; on a home folder the replay
    /// takes ~4 s of FSEvents daemon time, so it never blocks launch. With no
    /// snapshot, `watch` also builds one in the background (Spotlight answers
    /// meanwhile). Without `watch` (the CLI) the snapshot is used as it stands.
    @discardableResult
    public func enableFileIndexIfConfigured(watch: Bool) -> FileIndexService? {
        guard fileIndexEnabled, let service = try? makeFileIndexService() else { return nil }
        search.spotlight = IndexedFileSearch(service: service)
        // The CLI loads lazily on its first file search (`IndexedFileSearch`).
        guard watch else { return service }
        let loaded = (try? service.load()) == true
        DispatchQueue.global(qos: .utility).async {
            if !loaded {
                guard (try? service.build()) != nil else { return }
            }
            service.catchUp(keepWatching: true, timeout: 60)
        }
        return service
    }

    /// Stops watching, saves pending changes, and returns file search to Spotlight.
    public func disableFileIndex() {
        if let service = fileIndexService {
            service.stopWatching()
            try? service.saveIfDirty()
        }
        search.spotlight = MdfindSpotlightIndex()
    }
}
