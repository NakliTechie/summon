import Foundation
import Network

/// Agent face: UNIX domain socket (handoff §6).
///
/// **Default OFF** (Batch A 2026-08-04; aligns vision/handoff). Host starts the socket only when
/// `agent.socket.enabled` is true. Path: `…/Summon/summon.sock` (mode 0600).
/// Wire: one JSON line request → one JSON line response. Actor is always `.agent`.
public final class AgentSocketServer: @unchecked Sendable {
    /// Settings key; missing key means **disabled**.
    public static let enabledSettingKey = "agent.socket.enabled"

    public enum State: Sendable, Equatable {
        case stopped
        case listening
        case failed(String)
    }

    public let core: SummonCore
    public private(set) var state: State = .stopped
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "summon.agent-socket")

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
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: url)
        }

        let params = NWParameters()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        params.allowLocalEndpointReuse = true

        let real = try NWListener(using: params)
        real.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        real.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.state = .listening
                chmod(path, 0o600)
            case .failed(let error):
                self?.state = .failed(String(describing: error))
            case .cancelled:
                self?.state = .stopped
            default:
                break
            }
        }
        real.start(queue: queue)
        self.listener = real
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(on: connection, buffer: Data())
    }

    private func receiveLine(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data, !data.isEmpty {
                buf.append(data)
            }
            if error != nil {
                connection.cancel()
                return
            }
            if let nl = buf.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                let rest = buf.subdata(in: buf.index(after: nl)..<buf.endIndex)
                self.process(line: line, on: connection)
                if !rest.isEmpty {
                    self.receiveLine(on: connection, buffer: rest)
                }
                return
            }
            if isComplete {
                if !buf.isEmpty {
                    self.process(line: buf, on: connection)
                }
                connection.cancel()
                return
            }
            self.receiveLine(on: connection, buffer: buf)
        }
    }

    private func process(line: Data, on connection: NWConnection) {
        let response: Data
        do {
            response = try handleRequest(line)
        } catch {
            let msg = (error as? CoreError)?.message ?? error.localizedDescription
            response = (try? JSONSerialization.data(withJSONObject: [
                "ok": false,
                "error": msg,
            ])) ?? Data(#"{"ok":false,"error":"unknown"}"#.utf8)
        }
        var out = response
        out.append(UInt8(ascii: "\n"))
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Public for unit tests without binding a socket.
    public func handleRequest(_ data: Data) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String else {
            throw CoreError.schemaValidation("agent request requires op")
        }
        switch op {
        case "search":
            let q = obj["query"] as? String ?? ""
            let results = try core.search.search(q)
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
            guard let actionObj = obj["action"] else {
                throw CoreError.schemaValidation("dispatch requires action")
            }
            let actionData = try JSONSerialization.data(withJSONObject: actionObj)
            let result = try core.dispatchExternal(actionData, actor: .agent)
            return try JSONSerialization.data(withJSONObject: [
                "ok": result.isApplied,
                "envelopeID": result.envelopeID.uuidString,
            ])
        case "version":
            return try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "version": SummonVersion.string,
            ])
        default:
            throw CoreError.unknownAction(op)
        }
    }
}
