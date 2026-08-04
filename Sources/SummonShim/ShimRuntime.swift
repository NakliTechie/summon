import Foundation
import JavaScriptCore
import SummonCore

/// Per-extension JavaScriptCore context (D2: JSC-first).
///
/// One context per extension id. API surface is allow-listed; Node builtins and
/// filesystem `require` fail loud (sandbox).
public final class ShimRuntime: @unchecked Sendable {
    public let manifest: ExtensionManifest
    public let commandName: String
    private let context: JSContext
    private let storage: ShimStorage
    private let fetchHandler: (URL, String, [String: String], String?) throws -> FetchResponse
    private let entitlements: Set<String>
    private var toasts: [[String: Any]] = []
    /// Captured by exceptionHandler — JSC may clear `context.exception` after the handler returns.
    private var lastJSError: String?

    public struct FetchResponse: Sendable {
        public let ok: Bool
        public let status: Int
        public let statusText: String
        public let text: String
        /// Optional JSON body already serialized as a JSON string (parsed again for JS).
        public let jsonText: String?

        public init(ok: Bool, status: Int, statusText: String, text: String, jsonText: String? = nil) {
            self.ok = ok
            self.status = status
            self.statusText = statusText
            self.text = text
            self.jsonText = jsonText
        }
    }

    public enum RuntimeError: Error, Equatable, LocalizedError {
        case javascript(String)
        case bootstrapMissing
        case renderFailed(String)
        case entitlementDenied(String)

        public var errorDescription: String? {
            switch self {
            case .javascript(let s): return s
            case .bootstrapMissing: return "bootstrap missing"
            case .renderFailed(let s): return s
            case .entitlementDenied(let s): return s
            }
        }
    }

    /// - Parameter grantedEntitlements: User grants (canonical). Effective = declared ∩ granted.
    ///   Empty means no elevated host APIs (fetch denied). Tests pass declared set to simulate consent.
    public init(
        manifest: ExtensionManifest,
        commandName: String? = nil,
        storage: ShimStorage = ShimStorage(),
        grantedEntitlements: Set<String> = [],
        fetchHandler: ((URL, String, [String: String], String?) throws -> FetchResponse)? = nil
    ) throws {
        self.manifest = manifest
        self.commandName = commandName ?? manifest.commands.first?.name ?? "index"
        self.storage = storage
        let declared = Set(manifest.entitlements.map { ManifestGate.normalizeEntitlement($0) })
        let granted = Set(grantedEntitlements.map { ManifestGate.normalizeEntitlement($0) })
        self.entitlements = declared.intersection(granted)
        self.fetchHandler = fetchHandler ?? { _, _, _, _ in
            FetchResponse(ok: false, status: 404, statusText: "no fetch handler", text: "")
        }

        guard let context = JSContext() else {
            throw RuntimeError.javascript("JSContext allocation failed")
        }
        self.context = context
        // Capture exceptions here — after the handler returns, context.exception may be nil.
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastJSError = exception?.toString()
        }

        try installHostBridges()
        try loadBootstrap()
        try lockDownHostGlobals()
    }

    private func throwIfJSException(_ label: String) throws {
        if let message = lastJSError {
            lastJSError = nil
            context.exception = nil
            throw RuntimeError.javascript(message)
        }
        if let exc = context.exception {
            let message = exc.toString() ?? label
            context.exception = nil
            throw RuntimeError.javascript(message)
        }
    }

    // MARK: - Public API

    /// Evaluate extension entry source (CommonJS-shaped: sets module.exports).
    public func loadEntry(_ source: String, fileName: String = "command.js") throws {
        // Reset module.exports for this load.
        context.exception = nil
        lastJSError = nil
        _ = context.evaluateScript("module.exports = {}; exports = module.exports;")
        try throwIfJSException("module reset failed")
        lastJSError = nil
        _ = context.evaluateScript(source, withSourceURL: URL(string: "summon:///\(fileName)"))
        try throwIfJSException("entry evaluate failed")
    }

    /// Render the default command export to a host tree.
    public func render() throws -> HostNode {
        context.exception = nil
        lastJSError = nil
        let result = context.evaluateScript("__summon_render(module.exports)")
        if let message = lastJSError {
            lastJSError = nil
            throw RuntimeError.renderFailed(message)
        }
        try throwIfJSException("render exception")
        guard let json = result?.toString(), let data = json.data(using: .utf8) else {
            throw RuntimeError.renderFailed("render returned non-string")
        }
        // Guard against JS undefined/null leaking through as the string "undefined".
        guard json != "undefined", json != "null", json.hasPrefix("{") || json.hasPrefix("[") else {
            throw RuntimeError.renderFailed("render returned invalid JSON: \(json.prefix(80))")
        }
        do {
            return try decodeHostNode(from: data)
        } catch {
            throw RuntimeError.renderFailed("host tree decode: \(error.localizedDescription)")
        }
    }

    /// Load entry then render (fixture convenience).
    public func run(entrySource: String, fileName: String = "command.js") throws -> HostNode {
        try loadEntry(entrySource, fileName: fileName)
        return try render()
    }

    public func storageSnapshot() -> [String: String] {
        storage.all()
    }

    public func collectedToasts() -> [[String: Any]] {
        toasts
    }

    /// Effective host entitlements (declared ∩ user-granted).
    public var effectiveEntitlements: Set<String> { entitlements }

    // MARK: - Bootstrap + bridges

    private func loadBootstrap() throws {
        // Prefer bundle resource (Package resources); fall back to embedded SoT.
        let source: String
        if let url = Bundle.module.url(forResource: "shim-bootstrap", withExtension: "js"),
           let disk = try? String(contentsOf: url, encoding: .utf8),
           !disk.isEmpty {
            source = disk
        } else {
            source = ShimBootstrap.embeddedSource
        }
        guard !source.isEmpty else { throw RuntimeError.bootstrapMissing }
        _ = context.evaluateScript(source, withSourceURL: URL(string: "summon:///shim-bootstrap.js"))
        if let exc = context.exception {
            context.exception = nil
            throw RuntimeError.javascript("bootstrap: \(exc.toString() ?? "?")")
        }
        // Seed environment fields
        context.evaluateScript(
            """
            __summon.extensionName = \(jsonString(manifest.name));
            __summon.commandName = \(jsonString(commandName));
            if (typeof environment !== 'undefined') {
              environment.extensionName = __summon.extensionName;
              environment.commandName = __summon.commandName;
            }
            """
        )
    }

    /// Capture host blocks in a closure, delete global `__host*`, freeze `require`.
    private func lockDownHostGlobals() throws {
        context.evaluateScript(
            """
            (function () {
              var g = {
                get: globalThis.__hostStorageGet,
                set: globalThis.__hostStorageSet,
                remove: globalThis.__hostStorageRemove,
                clear: globalThis.__hostStorageClear,
                all: globalThis.__hostStorageAll,
                fetch: globalThis.__hostFetch,
                prefs: globalThis.__hostPreferences,
                selected: globalThis.__hostSelectedText
              };
              __summon.hostStorageGet = function(k) { return g.get(k); };
              __summon.hostStorageSet = function(k,v) { g.set(k,v); };
              __summon.hostStorageRemove = function(k) { g.remove(k); };
              __summon.hostStorageClear = function() { g.clear(); };
              __summon.hostStorageAll = function() { return g.all(); };
              __summon.hostFetch = function(u,m,h,b) { return g.fetch(u,m,h,b); };
              __summon.hostPreferences = function() { return g.prefs(); };
              __summon.hostSelectedText = function() { return g.selected(); };
              delete globalThis.__hostStorageGet;
              delete globalThis.__hostStorageSet;
              delete globalThis.__hostStorageRemove;
              delete globalThis.__hostStorageClear;
              delete globalThis.__hostStorageAll;
              delete globalThis.__hostFetch;
              delete globalThis.__hostPreferences;
              delete globalThis.__hostSelectedText;
              if (typeof require === 'function') {
                Object.freeze(require);
                try {
                  Object.defineProperty(globalThis, 'require', {
                    value: require, writable: false, configurable: false
                  });
                } catch (e) {}
              }
            })();
            """
        )
        if let exc = context.exception {
            context.exception = nil
            throw RuntimeError.javascript("host lockdown: \(exc.toString() ?? "?")")
        }
    }

    private func installHostBridges() throws {
        let storage = self.storage
        let entitlements = self.entitlements
        let fetchHandler = self.fetchHandler

        let storageGet: @convention(block) (String) -> String? = { key in
            storage.get(key)
        }
        let storageSet: @convention(block) (String, String) -> Void = { key, value in
            storage.set(key, value)
        }
        let storageRemove: @convention(block) (String) -> Void = { key in
            storage.remove(key)
        }
        let storageClear: @convention(block) () -> Void = {
            storage.clear()
        }
        let storageAll: @convention(block) () -> [String: String] = {
            storage.all()
        }

        context.setObject(storageGet, forKeyedSubscript: "__hostStorageGet" as NSString)
        context.setObject(storageSet, forKeyedSubscript: "__hostStorageSet" as NSString)
        context.setObject(storageRemove, forKeyedSubscript: "__hostStorageRemove" as NSString)
        context.setObject(storageClear, forKeyedSubscript: "__hostStorageClear" as NSString)
        context.setObject(storageAll, forKeyedSubscript: "__hostStorageAll" as NSString)

        // Wire bootstrap names onto __summon after bootstrap; pre-bind host fns on global for bootstrap assignment.
        let fetchBlock: @convention(block) (String, String, String, String?) -> String = { urlStr, method, headersJSON, body in
            do {
                // Effective grants only (declared ∩ user-granted); canonical token is `network`
                if !entitlements.contains("network") {
                    throw RuntimeError.entitlementDenied(
                        "fetch requires user-granted entitlement 'network'"
                    )
                }
                guard let url = URL(string: urlStr) else {
                    return Self.encodeFetch(
                        FetchResponse(ok: false, status: 0, statusText: "bad url", text: "")
                    )
                }
                var headers: [String: String] = [:]
                if let data = headersJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in obj {
                        headers[k] = String(describing: v)
                    }
                }
                let response = try fetchHandler(url, method, headers, body)
                return Self.encodeFetch(response)
            } catch {
                return Self.encodeFetch(
                    FetchResponse(ok: false, status: 0, statusText: error.localizedDescription, text: "")
                )
            }
        }
        context.setObject(fetchBlock, forKeyedSubscript: "__hostFetch" as NSString)

        let prefsBlock: @convention(block) () -> [String: Any] = {
            [:]
        }
        context.setObject(prefsBlock, forKeyedSubscript: "__hostPreferences" as NSString)

        let selectedText: @convention(block) () -> String = { "" }
        context.setObject(selectedText, forKeyedSubscript: "__hostSelectedText" as NSString)

        // Bridge bootstrap's __summon.host* to our global blocks after bootstrap via script:
        // installed in loadBootstrap finish — set now as globals the bootstrap will alias.
        context.evaluateScript(
            """
            var __summon = globalThis.__summon || {};
            globalThis.__summon = __summon;
            __summon.hostStorageGet = function(k) { return __hostStorageGet(k); };
            __summon.hostStorageSet = function(k,v) { __hostStorageSet(k,v); };
            __summon.hostStorageRemove = function(k) { __hostStorageRemove(k); };
            __summon.hostStorageClear = function() { __hostStorageClear(); };
            __summon.hostStorageAll = function() { return __hostStorageAll(); };
            __summon.hostFetch = function(u,m,h,b) { return __hostFetch(u,m,h,b); };
            __summon.hostPreferences = function() { return __hostPreferences(); };
            __summon.hostSelectedText = function() { return __hostSelectedText(); };
            """
        )
        if let exc = context.exception {
            throw RuntimeError.javascript("bridge install: \(exc.toString() ?? "?")")
        }
    }

    private static func encodeFetch(_ r: FetchResponse) -> String {
        var dict: [String: Any] = [
            "ok": r.ok,
            "status": r.status,
            "statusText": r.statusText,
            "text": r.text,
        ]
        let jsonSource = r.jsonText ?? r.text
        if let data = jsonSource.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(obj) || obj is String || obj is NSNumber || obj is NSNull {
            dict["json"] = obj
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"status":0,"statusText":"encode failed","text":""}"#
        }
        return s
    }

    private func decodeHostNode(from data: Data) throws -> HostNode {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try Self.node(from: obj)
    }

    private static func node(from any: Any) throws -> HostNode {
        guard let dict = any as? [String: Any] else {
            throw RuntimeError.renderFailed("node is not an object")
        }
        let type = dict["type"] as? String ?? "Unknown"
        let propsRaw = dict["props"] as? [String: Any] ?? [:]
        var props: [String: JSONValue] = [:]
        for (k, v) in propsRaw {
            props[k] = try jsonValue(from: v)
        }
        let childrenRaw = dict["children"] as? [Any] ?? []
        let children = try childrenRaw.map { try node(from: $0) }
        return HostNode(type: type, props: props, children: children)
    }

    private static func jsonValue(from any: Any) throws -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let n as NSNumber:
            // Distinguish bool (NSNumber) — already handled; treat as number
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(try a.map { try jsonValue(from: $0) })
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                out[k] = try jsonValue(from: v)
            }
            return .object(out)
        default:
            return .string(String(describing: any))
        }
    }

    private func jsonString(_ s: String) -> String {
        // JSONSerialization rejects top-level String; escape manually.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// In-memory per-extension storage (namespaced by caller; one instance per runtime).
public final class ShimStorage: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }

    public func all() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return map
    }
}
