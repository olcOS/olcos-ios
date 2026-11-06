import Foundation
import Mobile

// MARK: - XrayTunnelSession (#vpn, xray engine)
//
// The olcos-core (VLESS · REALITY) counterpart of the `MobileRuntime` the
// provider drives for olcrtc. One instance per tunnel start; owns the
// `OlcosRuntime`, forwards its log lines into the provider's ring buffer and
// exposes the two things `PacketTunnelProvider` needs: a synchronous
// `start(link:socksPort:)` that returns once the loopback SOCKS5 listener is
// bound, and `stop()`.
//
// Health: xray-core notices a rotated REALITY key or a dead server only when
// the first connection is attempted, so a successful `start` means the
// LISTENER is up. olcos-core classifies those first-traffic failures and
// forwards them as `health:{"reason":…,"raw":…}` lines through the log writer;
// they land in the ring buffer verbatim (the app reads it via the "logs"
// message) and flip `lastHealthReason`, which the provider's liveness watch
// folds into its data-path verdict.
//
// This target does not compile App/Core/XrayEngine.swift (project.yml: Tunnel/
// + VPNConfig only), so the envelope codec is duplicated here in its smallest
// form. Keep the two in step with olcos-core/olcos/olcos.go.
//
// NAMING CAUTION — gomobile spellings unverified on this machine; check
// Olcos.objc.h on the first CI bind (same list as App/Core/XrayEngine.swift):
//   OlcosNew() -> OlcosRuntime?, runtime.setLogWriter(_:),
//   runtime.invoke(_:jsonIn:) -> String, OlcosTuneForNetworkExtension(Int64),
//   OlcosFreeOSMemory(), OlcosLogWriterProtocol.write(_ level: Int, msg: String?).

final class XrayTunnelSession {

    struct CoreError: LocalizedError {
        let method: String
        let message: String
        var errorDescription: String? { "\(method): \(message)" }
    }

    private struct Envelope: Decodable { var ok: Bool; var error: String? }
    private struct StartWrapper: Decodable {
        struct R: Decodable { var socks_addr: String }
        var result: R
    }
    private struct Health: Decodable { var reason: String; var raw: String }

    static let healthLinePrefix = "health:"

    private let runtime: OlcosRuntime
    private let logCapture = XrayLogCapture()
    private let lock = NSLock()
    private var running = false
    private var _lastHealthReason: String?

    /// olcos-core reason string (keyMismatch, hostUnreachable, timedOut,
    /// networkDown, dnsUnreachable, carrierRejected) of the latest health
    /// event, nil while the session is healthy.
    var lastHealthReason: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastHealthReason
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// "running" / "stopped" — the shape `statsJSON` reports for olcrtc.
    var state: String { isRunning ? "running" : "stopped" }

    /// Nil when the olcos package is missing from the framework.
    init?(logBuffer: LogRingBuffer) {
        guard let rt = OlcosNew() else { return nil }
        runtime = rt
        // Capture the buffer and a weak self, never a strong self: the Go side
        // retains the writer for the life of the runtime.
        logCapture.onLog = { [buffer = logBuffer, weak self] level, line in
            if line.hasPrefix(Self.healthLinePrefix),
               let h = try? JSONDecoder().decode(Health.self,
                                                 from: Data(line.dropFirst(Self.healthLinePrefix.count).utf8)) {
                self?.setHealth(h.reason)
                buffer.append(line)              // verbatim: the app parses it
                buffer.append("health: \(h.reason) — \(h.raw)")
                return
            }
            // Level 3 is xray-core's per-connection debug chatter; the ring
            // buffer holds 400 lines and must keep the milestones.
            guard level <= 2 else { return }
            buffer.append(line)
        }
        rt.setLogWriter(logCapture)
    }

    private func setHealth(_ reason: String?) {
        lock.lock(); _lastHealthReason = reason; lock.unlock()
    }

    /// Binds the SOCKS5 listener on 127.0.0.1:`socksPort` and returns. Throws
    /// the core's own text (e.g. "address already in use", "invalid link").
    func start(link: String, socksPort: Int, direct: String = "") throws {
        // One session per Runtime: clear a leftover from an interrupted stop.
        _ = runtime.invoke("engine.stop", jsonIn: "{}")
        var input: [String: Any] = ["uri": link, "socks_port": socksPort]
        // Settings → Routing: listed destinations leave by Xray's direct outbound.
        if !direct.isEmpty { input["direct"] = direct }
        let data = try JSONSerialization.data(withJSONObject: input)
        let raw = runtime.invoke("engine.start", jsonIn: String(decoding: data, as: UTF8.self))
        guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(raw.utf8)) else {
            throw CoreError(method: "engine.start", message: "malformed envelope")
        }
        guard env.ok else { throw CoreError(method: "engine.start", message: env.error ?? "unknown error") }
        guard let wrapped = try? JSONDecoder().decode(StartWrapper.self, from: Data(raw.utf8)),
              wrapped.result.socks_addr.hasSuffix(":\(socksPort)") else {
            _ = runtime.invoke("engine.stop", jsonIn: "{}")
            throw CoreError(method: "engine.start", message: "core bound an unexpected SOCKS address")
        }
        lock.lock(); running = true; _lastHealthReason = nil; lock.unlock()
    }

    func stop() {
        _ = runtime.invoke("engine.stop", jsonIn: "{}")
        lock.lock(); running = false; lock.unlock()
    }
}

// Bridges olcos-core's `LogWriter` (Write(level int, msg string)) into a closure.
// Levels: 0 error, 1 warn, 2 info, 3 debug (olcos-core engine/engine.go).
private final class XrayLogCapture: NSObject, OlcosLogWriterProtocol {
    var onLog: ((Int, String) -> Void)?
    func write(_ level: Int, msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(level, msg)
    }
}
