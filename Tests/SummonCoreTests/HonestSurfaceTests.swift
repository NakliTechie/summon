import XCTest
@testable import SummonCore

final class HonestSurfaceTests: XCTestCase {
    func testProductionCoreConstructsLiveSearchWithoutFixtureSurfaces() throws {
        let container = temporaryContainer("production-construction")
        defer { try? FileManager.default.removeItem(at: container) }

        let core = try SummonCore(containerURL: container)

        XCTAssertTrue(core.search.spotlight is MdfindSpotlightIndex)
        XCTAssertNil(core.search.appIntents)
        XCTAssertNil(core.search.calendar)
    }

    func testUnavailablePermissionProbesRemainHonest() {
        let permissions = PermissionStatus.snapshot()

        XCTAssertNil(permissions.fullDiskAccess)
        XCTAssertNil(permissions.screenRecording)
    }

    func testEveryStarterRowHasARoutablePrimaryAction() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let executor = RecordingModuleExecutor()
        core.setExecutor(executor)

        for result in LauncherStarterCatalog.results(firstRun: true) {
            let session = LauncherSession(core: core)
            session.applyResults("", [result])
            XCTAssertNoThrow(try session.confirm(actor: .user), result.id)
        }

        XCTAssertEqual(
            Set(executor.calls.filter { $0.op == "app.navigate" }.map(\.value)),
            Set([
                AppDestination.search.rawValue,
                AppDestination.clipboard.rawValue,
                AppDestination.preferencesGeneral.rawValue,
                AppDestination.help.rawValue,
            ])
        )
        XCTAssertEqual(executor.pasteboard, "4")
    }

    func testSettingRowsRouteToTheirTaskGroupWithoutCopyingIdentifiers() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let executor = RecordingModuleExecutor()
        core.setExecutor(executor)

        let results = SettingsCatalog.search(query: "settings")
        XCTAssertEqual(results.count, SettingsCatalog.keys.count)
        for result in results {
            XCTAssertTrue(try core.invoke(actionName: "settings.open", result: result, actor: .user).isApplied)
        }

        XCTAssertEqual(executor.calls.filter { $0.op == "app.navigate" }.count, results.count)
        XCTAssertTrue(executor.pasteboard.isEmpty)
        XCTAssertEqual(
            Set(executor.calls.filter { $0.op == "app.navigate" }.map(\.value)),
            Set(PreferencesSection.allCases.map { $0.destination.rawValue })
        )
    }

    func testAdvertisedObjectActionsExcludePseudoPasteEditAndOpenWith() {
        let results = [
            SearchResult(id: "app:a", title: "A", kind: .app, path: "/Applications/A.app"),
            SearchResult(id: "file:a", title: "A", kind: .file, path: "/tmp/a"),
            SearchResult(id: "folder:a", title: "A", kind: .folder, path: "/tmp/a"),
            SearchResult(id: "snippet:a", title: "A", kind: .snippet),
            SearchResult(id: "calc:a", title: "4", kind: .calculation),
            SearchResult(id: "setting:a", title: "A", kind: .setting),
            SearchResult(id: "command:a", title: "A", kind: .command),
            SearchResult(id: "clipboard:a", title: "A", kind: .clipboard),
            SearchResult(id: "quicklink:a", title: "A", kind: .quicklink, path: "https://example.com"),
            SearchResult(id: "emoji:a", title: "A", kind: .emoji),
        ]
        let actions = results.flatMap { ObjectActionGrammar.actions(for: $0, isFavorite: false) }
        let names = Set(actions.map(\.name))
        let titles = actions.map(\.title)

        XCTAssertTrue(names.isDisjoint(with: [
            "file.openWith",
            "snippet.edit",
            "snippet.paste",
            "calc.paste",
            "clipboard.paste",
            "clipboard.pastePlain",
            "emoji.paste",
        ]))
        XCTAssertFalse(titles.contains { $0 == "Paste" || $0.hasPrefix("Paste ") })
        XCTAssertTrue(names.contains("clipboard.copyPlain"))
    }

    func testEmptyQueryCombinesStartersFavoritesAndRecentsWithManagement() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let executor = RecordingModuleExecutor()
        core.setExecutor(executor)
        let favorite = SearchResult(
            id: "app:Favorite",
            title: "Favorite",
            kind: .app,
            path: "/Applications/Favorite.app"
        )
        let recent = SearchResult(
            id: "file:Recent",
            title: "Recent.txt",
            kind: .file,
            path: "/tmp/Recent.txt"
        )

        XCTAssertTrue(try core.invoke(actionName: "favorite.add", result: favorite, actor: .user).isApplied)
        try core.recordUsage(result: recent, query: "recent")
        let stored = try core.search.search("")
        let combined = LauncherStarterCatalog.combined(firstRun: false, stored: stored)

        XCTAssertTrue(combined.contains { $0.id == favorite.id && $0.subtitle == "favorite" })
        XCTAssertTrue(combined.contains { $0.id == recent.id && $0.subtitle?.hasPrefix("recent") == true })

        let session = LauncherSession(core: core)
        session.applyResults("", [favorite])
        session.enterObjectMode()
        XCTAssertTrue(session.objectActions.contains { $0.name == "favorite.remove" })
        XCTAssertFalse(session.objectActions.contains { $0.name == "favorite.add" })

        XCTAssertTrue(try core.invoke(actionName: "favorite.remove", result: favorite, actor: .user).isApplied)
        XCTAssertFalse(try core.favorites.contains(resultID: favorite.id))
    }

    private func temporaryContainer(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}
