import Foundation
import Darwin
import XCTest
@testable import SummonCore

final class AgentSocketTests: XCTestCase {
    func testVersionOp() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let data = try server.handleRequest(Data(#"{"op":"version"}"#.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["version"] as? String, SummonVersion.string)
    }

    func testSearchOp() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let data = try server.handleRequest(Data(#"{"op":"search","query":"2+2"}"#.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let results = obj?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["kind"] as? String, "calculation")
        let entry = try XCTUnwrap(core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .agent)
        XCTAssertEqual(entry.action, .agentSearch(query: "2+2", includedSensitive: false))
    }

    func testDispatchOpJournalsAgent() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        // Non-restricted settings key (agent.* is propose-only)
        let req = """
        {"op":"dispatch","action":{"v":1,"action":"settings.set","key":"cli.test.flag","value":true}}
        """
        let data = try server.handleRequest(Data(req.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(try core.settings.get("cli.test.flag"), .bool(true))
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.last?.actor, .agent)
    }

    func testDispatchRestrictedSettingStages() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let req = """
        {"op":"dispatch","action":{"v":1,"action":"settings.set","key":"agent.socket.enabled","value":true}}
        """
        let data = try server.handleRequest(Data(req.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // staged, not applied
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["outcome"] as? String, "staged")
        XCTAssertNotNil(obj?["proposalID"] as? String)
        XCTAssertNil(try core.settings.get("agent.socket.enabled"))
        let staged = try core.staged.list(state: "staged")
        XCTAssertFalse(staged.isEmpty)
    }

    func testUnknownOpFails() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        XCTAssertThrowsError(try server.handleRequest(Data(#"{"op":"teleport"}"#.utf8)))
    }

    func testDefaultEnabledSettingKey() {
        XCTAssertEqual(AgentSocketServer.enabledSettingKey, "agent.socket.enabled")
        XCTAssertEqual(
            AgentSocketServer.sensitiveSearchGrantSettingKey,
            "agent.search.sensitive.enabled"
        )
    }

    func testDispatchRejectsEveryNonObjectActionShape() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let invalid: [Any] = ["text", 7, true, NSNull(), ["array"]]
        for action in invalid {
            let request = try JSONSerialization.data(withJSONObject: [
                "op": "dispatch",
                "action": action,
            ])
            XCTAssertThrowsError(try server.handleRequest(request))
        }
    }

    func testDispatchRejectsDeferredExtensionAuthorityBeforeStaging() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: executor)
        let server = AgentSocketServer(core: core)
        let requests = [
            #"""
            {"op":"dispatch","action":{
              "v":1,"action":"extension.install","sourcePath":"/tmp/example-extension"
            }}
            """#,
            #"""
            {"op":"dispatch","action":{
              "v":1,"action":"extension.grant","extensionID":"example",
              "entitlement":"network","granted":true
            }}
            """#,
        ]

        for request in requests {
            XCTAssertThrowsError(try server.handleRequest(Data(request.utf8)))
        }
        XCTAssertTrue(try core.staged.list(state: "staged").isEmpty)
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testRejectsOversizedAndUnknownRequestFields() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let oversized = try JSONSerialization.data(withJSONObject: [
            "op": "search",
            "query": String(repeating: "x", count: AgentSocketServer.maximumFrameBytes),
        ])
        XCTAssertGreaterThan(oversized.count, AgentSocketServer.maximumFrameBytes)
        XCTAssertThrowsError(try server.handleRequest(oversized))
        XCTAssertThrowsError(
            try server.handleRequest(Data(#"{"op":"version","extra":true}"#.utf8))
        )
        XCTAssertThrowsError(
            try server.handleRequest(Data(#"{"op":"search","includeSensitive":1}"#.utf8))
        )
    }

    func testSearchRequiresRequestAndSeparateUserGrantForSensitiveStores() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .snippetUpsert(
                id: "socket-snippet",
                name: "socket-secret snippet",
                body: "socket-secret body",
                keyword: nil
            ),
            actor: .user
        )
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "socket-clipboard",
                text: "socket-secret clipboard",
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let server = AgentSocketServer(core: core)

        var kinds = try searchKinds(server, includeSensitive: true)
        XCTAssertFalse(kinds.contains("snippet"))
        XCTAssertFalse(kinds.contains("clipboard"))

        _ = try core.dispatch(
            action: .settingsSet(
                key: AgentSocketServer.sensitiveSearchGrantSettingKey,
                value: .bool(true)
            ),
            actor: .user
        )
        kinds = try searchKinds(server, includeSensitive: false)
        XCTAssertFalse(kinds.contains("snippet"))
        XCTAssertFalse(kinds.contains("clipboard"))

        kinds = try searchKinds(server, includeSensitive: true)
        XCTAssertTrue(kinds.contains("snippet"))
        XCTAssertTrue(kinds.contains("clipboard"))
    }

    func testAgentOverwriteUpsertsStageWithoutMutation() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let firstSnippet = """
        {"op":"dispatch","action":{"v":1,"action":"snippet.upsert","id":"stable","key":"Name","body":"old"}}
        """
        var response = try responseObject(server, request: firstSnippet)
        XCTAssertEqual(response["outcome"] as? String, "applied")

        let overwriteSnippet = """
        {"op":"dispatch","action":{"v":1,"action":"snippet.upsert","id":"stable","key":"Name","body":"new"}}
        """
        response = try responseObject(server, request: overwriteSnippet)
        XCTAssertEqual(response["outcome"] as? String, "staged")
        XCTAssertEqual(try core.snippets.get(id: "stable")?.body, "old")

        let firstQuicklink = """
        {"op":"dispatch","action":{"v":1,"action":"quicklink.upsert","id":"stable-q","key":"Docs","url":"https://example.com/old"}}
        """
        response = try responseObject(server, request: firstQuicklink)
        XCTAssertEqual(response["outcome"] as? String, "applied")

        let overwriteQuicklink = """
        {"op":"dispatch","action":{"v":1,"action":"quicklink.upsert","id":"stable-q","key":"Docs","url":"https://example.com/new"}}
        """
        response = try responseObject(server, request: overwriteQuicklink)
        XCTAssertEqual(response["outcome"] as? String, "staged")
        XCTAssertEqual(try core.quicklinks.get(id: "stable-q")?.url, "https://example.com/old")
    }

    func testEnabledSocketTransportWalkthrough() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(
                key: AgentSocketServer.enabledSettingKey,
                value: .bool(true)
            ),
            actor: .user
        )
        XCTAssertEqual(try core.settings.get(AgentSocketServer.enabledSettingKey), .bool(true))

        let root = URL(
            fileURLWithPath: "/private/tmp/summon-socket-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let socket = root.appendingPathComponent("summon.sock")
        let server = AgentSocketServer(core: core)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start(socketURL: socket)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socket.path),
            "listener state: \(server.state)"
        )

        let response = try unixSocketRequest(
            path: socket.path,
            request: #"{"op":"version"}"#
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["version"] as? String, SummonVersion.string)

        let oversizedResponse = try unixSocketRequest(
            path: socket.path,
            request: String(repeating: "x", count: AgentSocketServer.maximumFrameBytes + 1)
        )
        let oversizedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: oversizedResponse) as? [String: Any]
        )
        XCTAssertEqual(oversizedObject["outcome"] as? String, "rejected")
        XCTAssertTrue((oversizedObject["error"] as? String)?.contains("frame byte limit") == true)
    }

    func testVersionReadIsJournaledAsAgent() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        _ = try server.handleRequest(Data(#"{"op":"version"}"#.utf8))
        let entry = try XCTUnwrap(core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .agent)
        XCTAssertEqual(entry.action, .agentVersion)
    }

    func testModuleRunStagesBeforeExecutor() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: executor)
        let server = AgentSocketServer(core: core)
        let request = """
        {"op":"dispatch","action":{"v":1,"action":"module.run","module":"window.arrange",\
        "targetID":"window:leftHalf","payload":{"layout":"leftHalf","gap":8}}}
        """
        let response = try responseObject(server, request: request)
        XCTAssertEqual(response["outcome"] as? String, "staged")
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testStalledClientDoesNotBlockConcurrentVersionRequest() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(true)),
            actor: .user
        )
        let root = temporarySocketRoot()
        let socket = root.appendingPathComponent("summon.sock")
        let server = AgentSocketServer(core: core)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start(socketURL: socket)
        let stalled = try openUnixSocket(path: socket.path)
        defer { Darwin.close(stalled) }
        let partial = [UInt8(ascii: "{")]
        _ = partial.withUnsafeBytes { bytes in
            Darwin.write(stalled, bytes.baseAddress, bytes.count)
        }
        Thread.sleep(forTimeInterval: 0.05)

        let started = Date()
        let response = try unixSocketRequest(path: socket.path, request: #"{"op":"version"}"#)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testOneRequestPerConnectionDropsPipelinedFramesWithoutExecutingThem() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(true)),
            actor: .user
        )
        let root = temporarySocketRoot()
        let socket = root.appendingPathComponent("summon.sock")
        let server = AgentSocketServer(core: core)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start(socketURL: socket)

        let client = try openUnixSocket(path: socket.path)
        defer { Darwin.close(client) }
        let requests = Data("{\"op\":\"version\"}\n{\"op\":\"version\"}\n".utf8)
        _ = requests.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        _ = shutdown(client, SHUT_WR)
        let response = readUntilEOF(client)

        XCTAssertEqual(response.split(separator: UInt8(ascii: "\n")).count, 1)
        XCTAssertEqual(
            try core.journal.allEntries().filter { $0.action == .agentVersion }.count,
            1
        )
    }

    func testLifecycleRevokesAndUnlinksLiveSocket() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(true)),
            actor: .user
        )
        let root = temporarySocketRoot()
        let socket = root.appendingPathComponent("summon.sock")
        let lifecycle = AgentSocketLifecycleController(core: core, socketURL: socket)
        defer {
            lifecycle.stop()
            try? FileManager.default.removeItem(at: root)
        }
        guard case .listening = lifecycle.reconcile() else {
            return XCTFail("expected listener")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertFalse(
            try unixSocketRequest(path: socket.path, request: #"{"op":"version"}"#).isEmpty
        )

        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(false)),
            actor: .user
        )
        guard case .disabled = lifecycle.reconcile() else {
            return XCTFail("expected disabled lifecycle")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertThrowsError(try openUnixSocket(path: socket.path))
    }

    func testPartialFrameCannotDispatchAfterRevocation() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(true)),
            actor: .user
        )
        let root = temporarySocketRoot()
        let socket = root.appendingPathComponent("summon.sock")
        let server = AgentSocketServer(core: core)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start(socketURL: socket)
        let client = try openUnixSocket(path: socket.path)
        defer { Darwin.close(client) }
        let partial = Data(#"{"op":"ver"#.utf8)
        _ = partial.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        Thread.sleep(forTimeInterval: 0.05)

        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(false)),
            actor: .user
        )
        let remainder = Data("sion}\n".utf8)
        _ = remainder.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertFalse(try core.journal.allEntries().contains { $0.action == .agentVersion })
    }

    func testBootstrapFailureDoesNotDisableCore() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .settingsSet(key: AgentSocketServer.enabledSettingKey, value: .bool(true)),
            actor: .user
        )
        let root = temporarySocketRoot()
        let socket = root.appendingPathComponent("summon.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: socket)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .failed(let message) = AgentSocketBootstrap.startIfEnabled(
            core: core,
            socketURL: socket
        ) else {
            return XCTFail("expected bootstrap failure")
        }
        XCTAssertTrue(message.contains("refusing to replace non-socket"))
        let result = try core.dispatch(
            action: .settingsSet(key: "core.usable", value: .bool(true)),
            actor: .user
        )
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try core.settings.get("core.usable"), .bool(true))
    }

    private func searchKinds(
        _ server: AgentSocketServer,
        includeSensitive: Bool
    ) throws -> Set<String> {
        let request = try JSONSerialization.data(withJSONObject: [
            "op": "search",
            "query": "socket-secret",
            "includeSensitive": includeSensitive,
        ])
        let data = try server.handleRequest(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["results"] as? [[String: Any]])
        return Set(rows.compactMap { $0["kind"] as? String })
    }

    private func responseObject(
        _ server: AgentSocketServer,
        request: String
    ) throws -> [String: Any] {
        let data = try server.handleRequest(Data(request.utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func unixSocketRequest(path: String, request: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-w", "2", "-U", path]
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        input.fileHandleForWriting.write(Data("\(request)\n".utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? "nc failed"
        )
        return data
    }

    private func temporarySocketRoot() -> URL {
        URL(
            fileURLWithPath: "/private/tmp/summon-socket-test-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func openUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreError.io("test socket failed") }
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw CoreError.io("test connect failed")
        }
        return fd
    }

    private func readUntilEOF(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return output
            }
        }
    }
}
