import Foundation
import Mobile

// MARK: - OlcosBridge
//
// The gobind surface of olcos-core's `olcos` package (bound into the same
// Mobile.xcframework as upstream's `mobile` and our `tunstack` — see
// scripts/build-framework.sh). The core speaks ONE JSON method channel,
// `Runtime.Invoke(method, jsonIn) -> envelope`, so the Swift side stays a
// thin codec: no per-setter bindings to keep in sync with Go.
//
// Envelope (olcos/olcos.go `reply`): {"ok":bool,"error"?:string,"result"?:any}.
//
// Compiled into the app target only. The packet-tunnel extension has its own
// copy of the same three helpers in Tunnel/XrayTunnelSession.swift — the two
// processes link separate Go runtimes and share no Swift sources beyond
// VPNConfig (project.yml).

enum OlcosBridge {

    struct Envelope: Decodable {
        var ok: Bool
        var error: String?
    }

    struct StartResult: Decodable {
        var socks_addr: String
        var owns_tun: Bool
    }

    struct ProbeResult: Decodable {
        var rtt_ms: Int64
    }

    struct HealthEvent: Decodable, Equatable {
        var reason: String
        var raw: String
    }

    /// Prefix the core puts on health lines it forwards through the log
    /// writer (olcos/olcos.go `start`: `r.emit(1, "health:"+json)`).
    static let healthLinePrefix = "health:"

    /// Typed view of the `result` member; Swift forbids nesting generic types
    /// inside a generic function, so it lives at enum scope.
    private struct ResultWrapper<R: Decodable>: Decodable { var result: R }

    struct InvokeError: Error, CustomStringConvertible {
        let method: String
        let message: String
        var description: String { "\(method): \(message)" }
    }

    /// Decodes the envelope and, on `ok`, the typed `result`. Throws the core's
    /// own error text otherwise — the callers classify it.
    static func decode<T: Decodable>(_ raw: String, as type: T.Type, method: String) throws -> T {
        let data = Data(raw.utf8)
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw InvokeError(method: method, message: "malformed envelope: \(raw.prefix(200))")
        }
        guard env.ok else { throw InvokeError(method: method, message: env.error ?? "unknown error") }
        do {
            return try JSONDecoder().decode(ResultWrapper<T>.self, from: data).result
        } catch {
            throw InvokeError(method: method, message: "malformed result: \(error)")
        }
    }

    /// `health:{...}` → event, nil for any other line.
    static func healthEvent(fromLogLine line: String) -> HealthEvent? {
        guard line.hasPrefix(healthLinePrefix) else { return nil }
        let json = line.dropFirst(healthLinePrefix.count)
        return try? JSONDecoder().decode(HealthEvent.self, from: Data(json.utf8))
    }

    /// The SOCKS port out of "127.0.0.1:18089".
    static func port(fromSocksAddr addr: String) -> Int? {
        guard let colon = addr.lastIndex(of: ":") else { return nil }
        return Int(addr[addr.index(after: colon)...])
    }

    /// Request body for engine.start / engine.probe from a saved connection.
    static func startInput(_ p: XrayConnection, socksPort: Int?, timeoutMs: Int? = nil,
                           direct: String = "") -> String {
        var dict: [String: Any] = ["uri": XrayURI.encode(p)]
        if let socksPort { dict["socks_port"] = socksPort }
        if let timeoutMs { dict["timeout_ms"] = timeoutMs }
        // Settings → Routing: listed destinations leave by Xray's direct outbound.
        if !direct.isEmpty { dict["direct"] = direct }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// Bridges olcos-core's `LogWriter` (Write(level int, msg string)) into a Swift
// closure. Levels: 0 error, 1 warn, 2 info, 3 debug (engine/engine.go).
private final class OlcosLogCapture: NSObject, OlcosLogWriterProtocol {
    var onLog: ((Int, String) -> Void)?
    func write(_ level: Int, msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(level, msg)
    }
}

// MARK: - XrayEngine
//
// The VLESS + REALITY backend behind `ConnectionDetails.xray`. Owns the ONE
// `OlcosRuntime` of the app process (olcos-core allows a single session per
// Runtime; `engine.start` on a running one fails with "engine already running").
// Same lifecycle contract as `OlcrtcEngine`: `start` binds the SOCKS5 listener
// on the port TunnelManager allocated, TunnelManager then verifies the path end
// to end (HTTPS through the listener) and owns every state transition.
//
// Health: xray-core reports a bad public key / unreachable server only when the
// first connection is attempted, so `start` succeeding says the LISTENER is up,
// not that the server accepted us. olcos-core classifies those first-traffic
// failures (engine/xray/health.go) and forwards them as `health:{…}` log lines;
// `lastHealth` keeps the latest so the verify step's failure can be explained.
final class XrayEngine: TunnelEngine, @unchecked Sendable {
    static let shared = XrayEngine()

    private let logCapture = OlcosLogCapture()
    private let runtime: OlcosRuntime
    private let lock = NSLock()
    private var running = false
    private var _lastHealth: OlcosBridge.HealthEvent?

    /// The most recent health event of the current session (nil after `start`).
    var lastHealth: OlcosBridge.HealthEvent? {
        lock.lock(); defer { lock.unlock() }
        return _lastHealth
    }

    private init() {
        guard let rt = OlcosNew() else {
            fatalError("OlcosNew() returned nil — Mobile.xcframework is missing the olcos package")
        }
        runtime = rt
        logCapture.onLog = { [weak self] level, msg in
            if let ev = OlcosBridge.healthEvent(fromLogLine: msg) {
                self?.recordHealth(ev)
                let reason = HealthFailureMapper.reason(forXrayReason: ev.reason)
                Task { @MainActor in
                    LogStore.shared.log(.connection, "✗ \(reason.message) — \(ev.raw)")
                }
                return
            }
            // Level 3 (debug) is xray-core's per-connection chatter; keep the
            // connection log readable.
            guard level <= 2 else { return }
            Task { @MainActor in LogStore.shared.log(.connection, msg) }
        }
        rt.setLogWriter(logCapture)
    }

    private func recordHealth(_ ev: OlcosBridge.HealthEvent) {
        lock.lock(); _lastHealth = ev; lock.unlock()
    }

    private func setRunning(_ value: Bool) {
        lock.lock(); running = value; if value { _lastHealth = nil }; lock.unlock()
    }

    // MARK: TunnelEngine

    func validate(_ details: ConnectionDetails) -> String? {
        guard case .xray(let p) = details else { return nil }
        return TunnelManager.validate(xray: p)
    }

    func stop() {
        _ = runtime.invoke("engine.stop", jsonIn: "{}")
        setRunning(false)
    }

    func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start(_ details: ConnectionDetails, port: Int, settings s: EngineStartSettings) async throws {
        guard case .xray(let p) = details else {
            throw TunnelEngineError("internal: XrayEngine received non-xray details", reason: .unknown)
        }
        await MainActor.run {
            LogStore.shared.log(.connection,
                L10n.connectingXray_fmt.formatted(p.host, p.port, p.sni),
                code: .connecting)  // OLC-1002
        }
        // Only one session per Runtime — a leftover from an interrupted stop
        // must not turn this start into "engine already running".
        _ = runtime.invoke("engine.stop", jsonIn: "{}")
        setRunning(false)

        if s.localSocksAuthEnabled {
            // The xray SOCKS5 inbound is rendered without accounts (olcos-core
            // xray.render_client); a SOCKS client that offers NO_AUTH alongside
            // username/password still connects, one that insists on auth does not.
            await MainActor.run {
                LogStore.shared.log(.connection, L10n.xrayLocalSocksAuthIgnored.localized())
            }
        }

        let runtime = self.runtime
        let input = OlcosBridge.startInput(p, socksPort: port, direct: s.directRules)
        let result: OlcosBridge.StartResult = try await Task.detached {
            let raw = runtime.invoke("engine.start", jsonIn: input)
            do {
                return try OlcosBridge.decode(raw, as: OlcosBridge.StartResult.self, method: "engine.start")
            } catch let e as OlcosBridge.InvokeError {
                throw TunnelEngineError(Self.startErrorMessage(e.message, port: port),
                                        reason: HealthFailureMapper.reason(forRaw: e.message))
            }
        }.value
        guard OlcosBridge.port(fromSocksAddr: result.socks_addr) == port else {
            stop()
            throw TunnelEngineError("internal: core bound \(result.socks_addr), expected port \(port)", reason: .unknown)
        }
        setRunning(true)
    }

    /// User-facing text for an engine.start failure. The port clash is the one
    /// case with a specific, actionable sentence in the shared vocabulary.
    static func startErrorMessage(_ raw: String, port: Int) -> String {
        let s = raw.lowercased()
        if s.contains("address already in use") || s.contains("bind:") {
            return L10n.errorPortBusy_fmt.formatted(port)
        }
        return raw
    }

    // MARK: Probes
    //
    // ping → engine.ping: an HTTP round trip through a temporary Xray client,
    // measured exactly like the olcrtc core's ping (google generate_204, one
    // warm-up, best of three). It fails on a wrong UUID or key, so its success
    // is the evidence HealthCoordinator may call verified, and its milliseconds
    // compare with an olcrtc connection's.
    // engine.probe was the ping until then: a TCP connect to host:port only,
    // which any open port passes. It stays as the quick checkReady.

    func ping(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        await measure("engine.ping", details, timeoutMs: s.timeoutMs)
    }

    func checkReady(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        await measure("engine.probe", details, timeoutMs: s.timeoutMs)
    }

    private func measure(_ method: String, _ details: ConnectionDetails, timeoutMs: Int) async -> PingOutcome {
        guard case .xray(let p) = details else { return .failure(L10n.pingFailed.localized()) }
        let runtime = self.runtime
        let input = OlcosBridge.startInput(p, socksPort: nil, timeoutMs: timeoutMs)
        return await Task.detached {
            let raw = runtime.invoke(method, jsonIn: input)
            do {
                let r = try OlcosBridge.decode(raw, as: OlcosBridge.ProbeResult.self, method: method)
                return PingOutcome.success(ms: Int(r.rtt_ms))
            } catch let e as OlcosBridge.InvokeError {
                return PingOutcome.failure(e.message)
            } catch {
                return PingOutcome.failure(L10n.pingFailed.localized())
            }
        }.value
    }
}

/* NAMING CAUTION — verify against the generated Olcos.objc.h on the first CI
   bind (this machine cannot run gomobile). Expected gomobile spellings for
   olcos-core/olcos/olcos.go:
     OlcosNew() -> OlcosRuntime?                        (func New() *Runtime)
     runtime.setLogWriter(_:)                           (SetLogWriter(w LogWriter))
     runtime.setSocksPort(_:) / setTunFD(_:)            (int setters, non-throwing)
     runtime.invoke(_:jsonIn:) -> String                (Invoke(method, jsonIn string) string)
     runtime.stop() throws                              (Stop() error)
     OlcosTuneForNetworkExtension(_:) / OlcosFreeOSMemory()
     OlcosLogWriterProtocol.write(_:msg:)               (Write(level int, msg string))
   `Runtime.start` is unexported in Go precisely because engine.Profile is not
   gobind-representable; everything goes through `invoke`. */
