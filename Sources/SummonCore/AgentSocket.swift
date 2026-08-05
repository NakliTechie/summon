import Foundation
import Darwin

/// Agent face: UNIX domain socket (handoff §6).
///
/// **Default OFF** (Batch A 2026-08-04; aligns vision/handoff). Host starts the socket only when
/// `agent.socket.enabled` is true. Path: `…/Summon/summon.sock` (mode 0600).
/// Wire: one JSON line request → one JSON line response. Actor is always `.agent`.
public final class AgentSocketServer: @unchecked Sendable {
    /// Settings key; missing key means **disabled**.
    public static let enabledSettingKey = "agent.socket.enabled"
    /// Separate user-owned grant for clipboard and snippet search results.
    public static let sensitiveSearchGrantSettingKey = "agent.search.sensitive.enabled"
    public static let maximumFrameBytes = SchemaGate.maximumDocumentBytes

    public enum State: Sendable, Equatable {
        case stopped
        case listening
        case failed(String)
    }

    public let core: SummonCore
    private let lifecycleLock = NSLock()
    private var storedState: State = .stopped
    private var listenerFD: Int32 = -1
    private var socketPath: String?
    private var activeClientFDs: Set<Int32> = []
    private let queue = DispatchQueue(label: "summon.agent-socket")
    private let clientQueue = DispatchQueue(
        label: "summon.agent-socket.clients",
        attributes: .concurrent
    )
    private let clientSlots = DispatchSemaphore(value: 8)
    private static let clientDeadlineSeconds: UInt64 = 2

    private struct WireRequest: Decodable {
        let op: String
        let query: String?
        let includeSensitive: Bool?
        let action: JSONValue?
    }

    public var state: State {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedState
    }

    public init(core: SummonCore) {
        self.core = core
    }

    public static func defaultSocketURL() throws -> URL {
        let dir = try SummonDatabase.defaultContainerURL()
        return dir.appendingPathComponent("summon.sock")
    }

    /// Start listening. Safe to call when already listening (no-op).
    public func start(socketURL: URL? = nil) throws {
        if case .listening = state { return }
        let url = try socketURL ?? Self.defaultSocketURL()
        let path = url.path
        let parent = url.deletingLastPathComponent()
        // Parent dir mode 0700 so only the user can reach the socket
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        try Self.removeStaleSocket(at: path)

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw CoreError.io("agent socket path exceeds \(pathCapacity - 1) bytes")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError("socket") }
        do {
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw Self.socketError("bind") }
            guard chmod(path, 0o600) == 0 else { throw Self.socketError("chmod") }
            guard Darwin.listen(fd, SOMAXCONN) == 0 else { throw Self.socketError("listen") }
        } catch {
            Darwin.close(fd)
            _ = unlink(path)
            setState(.failed(error.localizedDescription))
            throw error
        }

        lifecycleLock.lock()
        listenerFD = fd
        socketPath = path
        storedState = .listening
        lifecycleLock.unlock()
        queue.async { [weak self] in self?.acceptConnections(listenerFD: fd) }
    }

    public func stop() {
        lifecycleLock.lock()
        let fd = listenerFD
        let path = socketPath
        let clients = Array(activeClientFDs)
        listenerFD = -1
        socketPath = nil
        storedState = .stopped
        lifecycleLock.unlock()
        if fd >= 0 {
            _ = shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for clientFD in clients {
            _ = shutdown(clientFD, SHUT_RDWR)
        }
        if let path { _ = unlink(path) }
    }

    deinit {
        stop()
    }

    private func acceptConnections(listenerFD: Int32) {
        while isCurrent(listenerFD: listenerFD) {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD >= 0 {
                if clientSlots.wait(timeout: .now()) == .success {
                    guard register(clientFD: clientFD, listenerFD: listenerFD) else {
                        Darwin.close(clientFD)
                        clientSlots.signal()
                        continue
                    }
                    clientQueue.async { [weak self] in
                        guard let self else {
                            Darwin.close(clientFD)
                            return
                        }
                        defer { self.clientSlots.signal() }
                        self.handle(clientFD: clientFD)
                    }
                } else {
                    write(
                        response: Self.rejectionResponse("agent socket is busy"),
                        clientFD: clientFD
                    )
                    Darwin.close(clientFD)
                }
                continue
            }
            if errno == EINTR { continue }
            guard isCurrent(listenerFD: listenerFD) else { return }
            failListener(listenerFD: listenerFD, message: Self.socketError("accept").message)
            return
        }
    }

    private func handle(clientFD: Int32) {
        defer {
            unregister(clientFD: clientFD)
            Darwin.close(clientFD)
        }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        let response: Data
        do {
            try validatePeer(clientFD: clientFD)
            guard try core.settings.get(Self.enabledSettingKey) == .bool(true) else {
                stop()
                throw CoreError.io("agent socket is disabled")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + Self.clientDeadlineSeconds * 1_000_000_000
            let frame = try readFrame(clientFD: clientFD, deadline: deadline)
            guard isAuthorized(clientFD: clientFD),
                  try core.settings.get(Self.enabledSettingKey) == .bool(true) else {
                throw CoreError.io("agent socket was revoked before dispatch")
            }
            response = try handleRequest(frame)
        } catch {
            let msg = (error as? CoreError)?.message ?? error.localizedDescription
            response = Self.rejectionResponse(msg)
        }
        write(response: response, clientFD: clientFD)
    }

    private func readFrame(clientFD: Int32, deadline: UInt64) throws -> Data {
        var frame = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            try Self.applyReadTimeout(clientFD: clientFD, deadline: deadline)
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(clientFD, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                let received = chunk.prefix(count)
                if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                    frame.append(contentsOf: received[..<newline])
                    guard frame.count <= Self.maximumFrameBytes else {
                        throw CoreError.schemaValidation("agent request exceeds frame byte limit")
                    }
                    return frame
                }
                frame.append(contentsOf: received)
                guard frame.count <= Self.maximumFrameBytes else {
                    throw CoreError.schemaValidation("agent request exceeds frame byte limit")
                }
                continue
            }
            if count == 0 { return frame }
            if errno == EINTR { continue }
            throw Self.socketError("read")
        }
    }

    private func validatePeer(clientFD: Int32) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(clientFD, &peerUID, &peerGID) == 0 else {
            throw Self.socketError("getpeereid")
        }
        guard peerUID == geteuid() else {
            throw CoreError.io("agent socket peer UID does not match the app user")
        }
    }

    private static func applyReadTimeout(clientFD: Int32, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { throw CoreError.io("agent socket read timed out") }
        let remaining = deadline - now
        var timeout = timeval(
            tv_sec: Int(remaining / 1_000_000_000),
            tv_usec: Int32((remaining % 1_000_000_000) / 1_000)
        )
        let result = withUnsafePointer(to: &timeout) {
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else { throw socketError("setsockopt") }
    }

    private func write(response: Data, clientFD: Int32) {
        var framed = response
        framed.append(UInt8(ascii: "\n"))
        framed.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    clientFD,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private func isCurrent(listenerFD: Int32) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return self.listenerFD == listenerFD
    }

    private func register(clientFD: Int32, listenerFD: Int32) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard self.listenerFD == listenerFD, storedState == .listening else { return false }
        activeClientFDs.insert(clientFD)
        return true
    }

    private func unregister(clientFD: Int32) {
        lifecycleLock.lock()
        activeClientFDs.remove(clientFD)
        lifecycleLock.unlock()
    }

    private func isAuthorized(clientFD: Int32) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedState == .listening && activeClientFDs.contains(clientFD)
    }

    private func failListener(listenerFD: Int32, message: String) {
        lifecycleLock.lock()
        guard self.listenerFD == listenerFD else {
            lifecycleLock.unlock()
            return
        }
        let path = socketPath
        self.listenerFD = -1
        socketPath = nil
        storedState = .failed(message)
        lifecycleLock.unlock()
        Darwin.close(listenerFD)
        if let path { _ = unlink(path) }
    }

    private func setState(_ state: State) {
        lifecycleLock.lock()
        storedState = state
        lifecycleLock.unlock()
    }

    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            let fileType = info.st_mode & mode_t(S_IFMT)
            guard fileType == mode_t(S_IFSOCK) else {
                throw CoreError.io("refusing to replace non-socket path \(path)")
            }
            guard unlink(path) == 0 else { throw socketError("unlink") }
        } else if errno != ENOENT {
            throw socketError("lstat")
        }
    }

    private static func socketError(_ operation: String) -> CoreError {
        let code = errno
        return CoreError.io("agent socket \(operation) failed: \(String(cString: strerror(code)))")
    }

    private static func rejectionResponse(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "ok": false,
            "outcome": "rejected",
            "error": message,
        ])) ?? Data(#"{"ok":false,"outcome":"rejected","error":"unknown"}"#.utf8)
    }

    /// Public for unit tests without binding a socket.
    public func handleRequest(_ data: Data) throws -> Data {
        let obj = try SchemaGate.decodeJSONObject(from: data)
        let request: WireRequest
        do {
            request = try JSONDecoder().decode(WireRequest.self, from: data)
        } catch {
            throw CoreError.schemaValidation("malformed agent request: \(error.localizedDescription)")
        }
        switch request.op {
        case "search":
            try SchemaGate.rejectUnknownFields(
                in: obj,
                allowed: ["op", "query", "includeSensitive"]
            )
            let q = request.query ?? ""
            let requestsSensitive = request.includeSensitive == true
            let hasGrant = try core.settings.get(Self.sensitiveSearchGrantSettingKey) == .bool(true)
            let includesSensitive = requestsSensitive && hasGrant
            let results = try core.search.search(
                q,
                includeSensitiveStores: includesSensitive
            )
            _ = try core.dispatch(
                action: .agentSearch(query: q, includedSensitive: includesSensitive),
                actor: .agent
            )
            let rows: [[String: Any]] = results.map { r in
                var d: [String: Any] = [
                    "id": r.id,
                    "title": r.title,
                    "kind": r.kind.rawValue,
                    "score": r.score,
                ]
                if let s = r.subtitle { d["subtitle"] = s }
                if let p = r.path { d["path"] = p }
                return d
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "results": rows])
        case "dispatch":
            try SchemaGate.rejectUnknownFields(in: obj, allowed: ["op", "action"])
            guard let action = request.action, case .object = action else {
                throw CoreError.schemaValidation("dispatch action must be an object")
            }
            let actionData = try JSONEncoder().encode(action)
            let result = try core.dispatchExternal(actionData, actor: .agent)
            var response: [String: Any] = [
                "ok": result.isApplied,
                "envelopeID": result.envelopeID.uuidString,
            ]
            switch result.outcome {
            case .applied:
                response["outcome"] = "applied"
            case .staged(let proposalID):
                response["outcome"] = "staged"
                response["proposalID"] = proposalID
            case .rejected(let reason):
                response["outcome"] = "rejected"
                response["reason"] = reason
            }
            return try JSONSerialization.data(withJSONObject: response)
        case "version":
            try SchemaGate.rejectUnknownFields(in: obj, allowed: ["op"])
            _ = try core.dispatch(action: .agentVersion, actor: .agent)
            return try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "version": SummonVersion.string,
            ])
        default:
            throw CoreError.unknownAction(request.op)
        }
    }
}

public enum AgentSocketBootstrap {
    public enum Outcome {
        case disabled
        case listening(AgentSocketServer)
        case failed(String)
    }

    public static func startIfEnabled(
        core: SummonCore,
        socketURL: URL? = nil
    ) -> Outcome {
        do {
            guard try core.settings.get(AgentSocketServer.enabledSettingKey) == .bool(true) else {
                return .disabled
            }
            let server = AgentSocketServer(core: core)
            try server.start(socketURL: socketURL)
            return .listening(server)
        } catch {
            let message = (error as? CoreError)?.message ?? error.localizedDescription
            _ = try? core.dispatch(
                action: .settingsSet(key: "agent.socket.lastError", value: .string(message)),
                actor: .system
            )
            return .failed(message)
        }
    }
}

/// Reconciles the live listener with the persisted opt-in setting.
public final class AgentSocketLifecycleController {
    public let core: SummonCore
    public let socketURL: URL?
    public private(set) var server: AgentSocketServer?

    public init(core: SummonCore, socketURL: URL? = nil) {
        self.core = core
        self.socketURL = socketURL
    }

    @discardableResult
    public func reconcile() -> AgentSocketBootstrap.Outcome {
        let enabled = (try? core.settings.get(AgentSocketServer.enabledSettingKey)) == .bool(true)
        guard enabled else {
            server?.stop()
            server = nil
            return .disabled
        }
        if let server, server.state == .listening {
            return .listening(server)
        }
        let outcome = AgentSocketBootstrap.startIfEnabled(core: core, socketURL: socketURL)
        if case .listening(let activeServer) = outcome {
            server = activeServer
        } else {
            server = nil
        }
        return outcome
    }

    public func stop() {
        server?.stop()
        server = nil
    }
}
