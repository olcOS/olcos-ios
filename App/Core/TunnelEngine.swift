import Foundation
import Mobile

// MARK: - TunnelEngine (#243)
//
// The iOS multi-protocol seam. A `TunnelEngine` is a pluggable tunnel backend.
// `TunnelManager` owns everything generic; the engine owns the protocol's
// native runtime — for olcrtc, the gomobile `MobileRuntime` instance exposed by
// `Mobile.xcframework` (upstream master's mobile.New() API; the old package-
// level Mobile* singleton is gone — #442).
//
// `start` / `ping` / `checkReady` wrap blocking native calls; they are invoked
// from detached tasks, so the protocol is `Sendable` and methods are non-isolated.

struct TunnelEngineError: Error {
    let message: String
    /// #456: a STABLE failure code classified at the throw site, where the raw
    /// (English, core-emitted) text is still available. `message` is the
    /// user-facing string and is often ALREADY LOCALIZED here (connectNoPeer,
    /// errorPortBusy_fmt, errorRuntimeStillStopping), so classifying it later by
    /// English substring silently failed for every non-English user — the health
    /// layer then filed a real failure as "couldn't check". nil ⇒ the receiver
    /// falls back to substring mapping.
    let reason: HealthReason?
    init(_ message: String, reason: HealthReason? = nil) {
        self.message = message
        self.reason = reason
    }
}

struct EngineStartSettings: Sendable {
    let dns:                   String
    let debugEnabled:          Bool
    let timeoutMs:             Int
    let vp8FPS:                Int
    let vp8Batch:              Int
    let localSocksAuthEnabled: Bool
    let localSocksUser:        String
    let localSocksPass:        String
    let isReconnect:           Bool
    /// The destinations reached directly, not through the tunnel
    /// (SettingsStore.directRules); "" for everything through it.
    var directRules:           String = ""
}

struct EngineProbeSettings: Sendable {
    let timeoutMs: Int
    let pingURL:   String
    let vp8FPS:    Int
    let vp8Batch:  Int
}

protocol TunnelEngine: Sendable {
    func start(_ details: ConnectionDetails, port: Int, settings: EngineStartSettings) async throws
    func stop()
    /// #445 (audit fix 2): is the native runtime currently holding a generation
    /// (starting / running / stopping)? Keep-alive treats `false` as an immediate
    /// hard failure: a dead runtime means the SOCKS listener is gone, and HTTP
    /// probes can't be trusted then — URLSession silently BYPASSES a refusing
    /// proxy and completes requests direct, reporting a false "tunnel OK".
    func isRunning() -> Bool
    func ping(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome
    func checkReady(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome
    func validate(_ details: ConnectionDetails) -> String?
}

extension ConnectionDetails {
    var engine: any TunnelEngine {
        switch self {
        case .olcrtc: return OlcrtcEngine.shared
        case .xray:   return XrayEngine.shared
        }
    }
}

// Bridges the Go log-writer protocol into a Swift closure. The core's own
// `mobile` package provides SetLogWriter / LogWriter (mobile/log.go, routing
// the stdlib `log` it writes through); the logflags build shim pins those
// lines to the time-only prefix this app parses (olcos-core/olcrtc/mobile/zz_olcos_logflags.go).
private final class LogCapture: NSObject, MobileLogWriterProtocol {
    var onLog: ((String) -> Void)?
    func writeLog(_ msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(msg)
    }
}

// MARK: - OlcrtcEngine
//
// The olcrtc backend. Owns the ONE `MobileRuntime` instance (mirror of the old
// Go singleton: master's Runtime returns ErrAlreadyRunning on a second Start,
// so one instance is the whole-app tunnel). `@unchecked Sendable`: both stored
// properties are assigned once in `init`; the runtime is internally mutex-
// guarded on the Go side (every setter takes r.mu).
final class OlcrtcEngine: TunnelEngine, @unchecked Sendable {
    static let shared = OlcrtcEngine()

    /// Go-side Stop() bound: blocks until the generation's goroutine exits or
    /// this many ms elapse (master's own default is 5 s; 0 would also mean 5 s).
    private static let stopTimeoutMs = 5_000

    private let logCapture = LogCapture()
    /// The master-API runtime. MUST come from `MobileNew()` — `MobileRuntime()`
    /// (gomobile's default ObjC init) wraps a ZERO-VALUE Go struct with no
    /// defaults and no client runner and cannot start a tunnel.
    private let runtime: MobileRuntime

    /// #440: optional observer of every core log line, on the MainActor.
    @MainActor static var coreLineObserver: ((String) -> Void)?
    /// Told the index of a lane of the running several-lane session that has
    /// stayed out of its room past `DeadLaneWatch.limit`, on the MainActor.
    @MainActor static var laneDeadObserver: ((Int) -> Void)?
    /// Told when every lane of the running several-lane session has left its
    /// room (or gone silent) at once, on the MainActor: the session as a
    /// whole may be dead, and the app checks it the way keep-alive does.
    @MainActor static var lanesDownObserver: (() -> Void)?

    /// Several lanes at once (OlcrtcConnection.lanes: extra rooms, other
    /// protocols): the extra lanes' own runtimes, and what joins them on the
    /// port apps use — the bond client, which carries every connection over
    /// all lanes, or the balancer, which hands each connection to one.
    /// Empty / nil for an ordinary one-room session. Guarded by `lanesLock`.
    private let lanesLock = NSLock()
    private var laneRuntimes: [MobileRuntime] = []
    private var balancer: LaneBalancer?
    private var bondClient: BondClient?
    /// Each lane's own loopback SOCKS port, in lane order; empty for one room.
    private var lanePortList: [Int] = []
    /// The watch that joins a lane again once its runtime has ended. The core
    /// walks its room once and leaves retrying to the host (olcos-core/olcrtc
    /// mobile/runtime.go, `failoverMaxCycles`): a one-room session has
    /// TunnelManager's reconnect loop for that, a lane of a several-lane
    /// session has only this watch — without it, every room that dropped out
    /// stayed out until the next connect. `stop()` bumps `laneEpoch`, so a
    /// restart already under way never outlives its session.
    private var laneWatch: Task<Void, Never>?
    private var laneEpoch = 0
    /// Orders the watch ending a lane stuck joining against `stop()`: lane 1
    /// is the engine's own runtime, which the next start reuses, so such a
    /// stop must never run across a stop and the start after it. Taken off
    /// the main actor only (the watch, `stop()`), never by the readers of
    /// `lanesLock`, which a Stop of seconds would freeze.
    private let laneRecycleLock = NSLock()
    /// How often the watch looks at the lanes.
    static let laneWatchInterval: Duration = .seconds(3)

    private init() {
        guard let rt = MobileNew() else {
            fatalError("MobileNew() returned nil — Mobile.xcframework is broken")
        }
        runtime = rt
        logCapture.onLog = { msg in
            Task { @MainActor in
                LogStore.shared.log(.connection, msg)
                Self.coreLineObserver?(msg)   // #440: feed the wedge detector
            }
        }
        // Shim hook: routes the Go core's stdlib log output into LogStore and
        // pins log flags to time-only (master no longer manages flags).
        MobileSetLogWriter(logCapture)
        // Note: master's Runtime installs providers itself (client.RegisterDefaults()
        // inside mobile.New()) — the old MobileSetProviders() call is gone.
    }

    func validate(_ details: ConnectionDetails) -> String? {
        guard case .olcrtc(let params) = details else { return nil }
        return TunnelManager.validate(params: params)
    }

    func stop() {
        // Waits for a lane the watch is ending (seconds at most).
        laneRecycleLock.lock()
        defer { laneRecycleLock.unlock() }
        // Extra lanes first, all at once: each Stop blocks until its session closes.
        let (balancer, bondClient, lanes, watch) = lanesLock.withLock {
            () -> (LaneBalancer?, BondClient?, [MobileRuntime], Task<Void, Never>?) in
            let taken = (self.balancer, self.bondClient, laneRuntimes, laneWatch)
            self.balancer = nil
            self.bondClient = nil
            laneRuntimes = []
            lanePortList = []
            laneWatch = nil
            laneEpoch &+= 1
            return taken
        }
        watch?.cancel()
        balancer?.stop()
        bondClient?.stop()
        if !lanes.isEmpty {
            DispatchQueue.concurrentPerform(iterations: lanes.count) { i in
                try? lanes[i].stop(Self.stopTimeoutMs)
            }
        }
        // Master Stop(ms) is idempotent (idle/stopped → nil) and blocks until the
        // WebRTC session fully closes (#409 relies on that), throwing only on the
        // stop-timeout — nothing useful to surface, teardown continues in Go.
        try? runtime.stop(Self.stopTimeoutMs)
    }

    /// #445 (audit fix 2): mirrors master `Runtime.IsRunning` (mobile/runtime.go)
    /// — true while a generation is starting/running/stopping. The Go getter takes
    /// the runtime mutex, so this is safe from any thread/actor.
    func isRunning() -> Bool {
        runtime.isRunning() || lanesLock.withLock { laneRuntimes.contains { $0.isRunning() } }
    }

    /// What each lane of a several-lane session has carried so far, in the
    /// order of `OlcrtcConnection.lanes`; nil for a one-room session. Safe
    /// from any thread.
    func laneBytes() -> [LaneBytes]? {
        let (balancer, bondClient) = lanesLock.withLock { (self.balancer, self.bondClient) }
        if let bondClient { return Self.parseLaneBytes(bondClient.laneBytes()) }
        return balancer?.laneBytes()
    }

    /// Whether each lane of a several-lane session is in its room right now,
    /// in the order of `OlcrtcConnection.lanes`; nil for a one-room session.
    /// A lane the watch is joining again reads false. Safe from any thread.
    func laneReady() -> [Bool]? {
        let lanes = lanesLock.withLock { laneRuntimes }
        guard !lanes.isEmpty else { return nil }
        return ([runtime] + lanes).map { $0.state() == "running" }
    }

    /// Each lane's own loopback SOCKS port while a several-lane session runs,
    /// in the order of `OlcrtcConnection.lanes` (same credentials as the
    /// public port): a check can go through one lane only. Empty otherwise.
    func lanePorts() -> [Int] {
        lanesLock.withLock { lanePortList }
    }

    /// PURE. The bond client's count: "rx:tx" per lane, comma-separated.
    static func parseLaneBytes(_ text: String) -> [LaneBytes]? {
        var lanes: [LaneBytes] = []
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ":")
            guard pair.count == 2, let rx = UInt64(pair[0]), let tx = UInt64(pair[1]) else { return nil }
            lanes.append(LaneBytes(rx: rx, tx: tx))
        }
        return lanes.isEmpty ? nil : lanes
    }

    /// Carrier-aware room-settle (#271) — unchanged.
    /// The account token the carrier joins with. Only WB Stream takes one;
    /// VK Calls refuses ANY non-empty token (olcos-core/olcrtc
    /// internal/auth/vkcalls), so a stray value must never reach another carrier.
    static func providerToken(_ params: OlcrtcConnection) -> String {
        providerToken(params, carrier: params.carrier)
    }

    /// The same rule for one lane of a whole-server connection.
    static func providerToken(_ params: OlcrtcConnection, carrier: String) -> String {
        carrier == "wbstream" ? params.wbToken : ""
    }

    static func rejoinSettleMs(carrier: String) -> Int {
        switch carrier.lowercased() {
        case "jitsi", "telemost": return 3000   // XMPP-MUC presence cleanup lag
        default:                  return 1500   // wbstream + anything new
        }
    }

    /// #308 port-busy mapping — unchanged, but note it is now applied to the
    /// waitReady failure (master's Start() returns before the SOCKS bind; a
    /// bind race surfaces from WaitReady via the generation error).
    static func startErrorReason(_ raw: String, port: Int) -> String {
        let lower = raw.lowercased()
        let portBusy = lower.contains("address already in use")
            || lower.contains("eaddrinuse")
            || (lower.contains("bind") && lower.contains("\(port)"))
        return portBusy ? L10n.errorPortBusy_fmt.formatted(port) : raw
    }

    /// #445 (audit fix 7): does a Start failure mean the runtime is still tearing
    /// down the PREVIOUS generation? Matches master's ErrAlreadyRunning text
    /// ("olcRTC runtime is already active", mobile/runtime.go). Deliberately
    /// narrow — "address already in use" (the bind race) must NOT match, it has
    /// its own mapping in `startErrorReason`. Pure → tested
    /// (Tests/TunnelEngineWaitErrorTests.swift).
    static func isAlreadyActiveError(_ raw: String) -> Bool {
        raw.lowercased().contains("already active")
    }

    /// #275: master WaitReady failure classification. The two readiness
    /// sentinels (mobile/runtime.go: ErrReadyTimeout "olcRTC runtime readiness
    /// timed out", ErrStoppedBeforeReady "olcRTC runtime stopped before
    /// becoming ready") mean no peer rendezvoused; anything else is a real
    /// start failure (bind race, provider/auth error) that fell out of the run
    /// goroutine. Pure → tested (Tests/TunnelEngineWaitErrorTests.swift).
    static func isNoPeerWaitError(_ raw: String) -> Bool {
        let l = raw.lowercased()
        return l.contains("readiness timed out") || l.contains("stopped before becoming ready")
    }

    // boc #470
    /// The providerToken setter and `Start()` under ONE lock. Master's `Start()`
    /// copies the SHARED defaults at that instant (mobile/runtime.go), and a
    /// health probe pins ITS node's token on the same defaults from a detached
    /// task (`ping` / `checkReady` below) — a probe landing between the setter
    /// and `Start()` made the live session join with the probed node's token
    /// (a wbstream primary auto-connecting while the launch sweep probes a
    /// telemost sibling ⇒ an empty token ⇒ the carrier rejects the join, and a
    /// manual retry "fixes" it). The probes take the same lock around their
    /// setter, so neither side writes inside the other's window. The reverse
    /// direction — a probe whose own snapshot inside `Ping` sees a token a
    /// concurrent start just set — is left as it was: a probe false-negative,
    /// never a wrong live session.
    private static let tokenLock = NSLock()

    private static func startLocked(_ runtime: MobileRuntime, token: String) throws {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        runtime.setProviderToken(token)
        try runtime.start()
    }

    private static func setTokenLocked(_ runtime: MobileRuntime, _ token: String) {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        runtime.setProviderToken(token)
    }
    // eoc #470

    func start(_ details: ConnectionDetails, port: Int, settings s: EngineStartSettings) async throws {
        guard case .olcrtc(let stored) = details else {
            throw TunnelEngineError("internal: OlcrtcEngine received non-olcrtc details", reason: .unknown)   // #456
        }
        // The record keeps the `default` placeholder; the room hears THIS
        // install's own id (see DeviceIdentity).
        let params = DeviceIdentity.resolving(stored)
        await MainActor.run {
            LogStore.shared.log(.connection,
                L10n.connectingOlcrtc_fmt.formatted(params.carrier, params.transport, params.clientID),
                code: .connecting)  // OLC-1002
        }

        // Thread-safety: every MobileRuntime setter takes the runtime's mutex on
        // the Go side (olcrtc master mobile/config.go — r.mu.Lock() in each), so
        // calling from a detached Task is safe without iOS-side serialisation.
        // `stop()` also ends a previous session's extra rooms.
        stop()
        // #271: carrier-aware settle on auto-reconnect — unchanged.
        if s.isReconnect {
            let settleMs = Self.rejoinSettleMs(carrier: params.carrier)
            if settleMs > 0 {
                await MainActor.run {
                    LogStore.shared.log(.connection,
                        L10n.rejoinSettle_fmt.formatted(Double(settleMs) / 1000.0))
                }
                try? await Task.sleep(for: .milliseconds(settleMs))
            }
        }

        if params.lanes.count > 1 {
            try await startLanes(params, port: port, settings: s)
            return
        }

        do {
            try Self.configure(runtime, params: params, lane: params.lanes[0], port: port, settings: s)
        } catch {
            let raw = (error as NSError).localizedDescription
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw)) }
            throw TunnelEngineError(Self.startErrorReason(raw, port: port),
                                    reason: HealthFailureMapper.reason(forRaw: raw))   // #456
        }

        do {
            // Master Start() validates the config snapshot and spawns the run
            // goroutine — it does NOT block on the bind any more.
            // #470 was: `try runtime.start()`
            try Self.startLocked(runtime, token: Self.providerToken(params))
        } catch {
            let raw = (error as NSError).localizedDescription
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw)) }
            // #445 (audit fix 7): stop-timeout ghost. The opening
            // `try? runtime.stop(5s)` above swallows ErrStopTimeout, so when the
            // previous generation's WebRTC teardown takes >5 s the runtime is
            // still state=stopping and Start throws ErrAlreadyRunning — which
            // used to surface verbatim as the raw, untranslated "olcRTC runtime
            // is already active". Give the ghost one longer bounded stop and
            // retry Start once; only then give up with a friendly, actionable
            // error. (#333's same-port wait covers only the port symptom — the
            // port can already be free while the goroutine still drains.)
            guard Self.isAlreadyActiveError(raw) else {
                throw TunnelEngineError(Self.startErrorReason(raw, port: port),
                                    reason: HealthFailureMapper.reason(forRaw: raw))   // #456
            }
            await MainActor.run {
                LogStore.shared.log(.connection,
                    "⏳ previous session still shutting down — waiting up to 10 s and retrying start once")
            }
            try? runtime.stop(10_000)
            do {
                // #470 was: `try runtime.start()` — a probe could have re-pinned
                // the token during the 10 s stop above; set it again with Start().
                try Self.startLocked(runtime, token: Self.providerToken(params))
            } catch {
                let raw2 = (error as NSError).localizedDescription
                await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw2)) }
                // #470: this is OUR teardown still draining, not a measurement of
                // the node. `.timedOut` is a node-level verdict (not inconclusive),
                // so the chip went red "failed just now" and the hero headlined
                // "Timed out — the test ran out of time" over the actionable
                // message. `.unknown` files it as "couldn't check" (action: retry).
                // #470 was: `reason: .timedOut`
                throw TunnelEngineError(L10n.errorRuntimeStillStopping.localized(), reason: .unknown)   // #456
            }
        }
        await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartOK.localized(), code: .nativeStartOK) }  // OLC-1003

        do {
            try runtime.waitReady(s.timeoutMs)
        } catch {
            let raw = (error as NSError).localizedDescription
            try? runtime.stop(Self.stopTimeoutMs)
            let diagnostic = await MainActor.run { () -> String in
                LogStore.shared.log(.connection, L10n.waitReadyFailed_fmt.formatted(raw))
                if Self.isNoPeerWaitError(raw) {
                    // #275: transport never reached ready — no peer in the room.
                    let d = L10n.connectNoPeer.localized()
                    LogStore.shared.log(.connection, d)
                    return d
                }
                // #308: real run failure (e.g. late port race) — surfaces here
                // now, not from Start.
                return Self.startErrorReason(raw, port: port)
            }
            // #456: classify from the RAW core text (English) captured above —
            // `diagnostic` may already be a localized sentence.
            let reason: HealthReason = Self.isNoPeerWaitError(raw)
                ? .noPeer
                : HealthFailureMapper.reason(forRaw: raw)
            throw TunnelEngineError(diagnostic, reason: reason)
        }
        await MainActor.run {
            LogStore.shared.log(.connection, L10n.waitReadyOK.localized())
            LogStore.shared.log(.connection, "✓ SOCKS5 proxy ready on port \(port)", code: .socksReady)  // OLC-1004
        }
    }

    /// The one setter sequence every runtime of a session gets — the shared
    /// runtime and each extra lane's. Master setters VALIDATE and THROW (the old
    /// API accepted silently): a bad DNS host:port, a non-64-hex key or an
    /// out-of-range port/option fails here with the Go error text.
    private static func configure(_ rt: MobileRuntime, params: OlcrtcConnection, lane: OlcrtcLane,
                                  port: Int, settings s: EngineStartSettings) throws {
        rt.setDebug(s.debugEnabled)
        try rt.setDNS(s.dns)
        try rt.setProvider(lane.carrier)        // telemost | vkcalls | salutejazz | mtslink | wbstream | jitsi
        try rt.setTransport(lane.transport)
        try rt.setRoom(lane.roomID)             // ID or URL, verbatim (old buildRoomURL was identity)
        rt.setDeviceID(params.clientID)         // old clientID == client.Config.DeviceID
        try rt.setKey(params.key)
        if lane.transport == "vp8channel" {
            // An MTS Link lane runs at least 60 / 64, and only that lane: the others keep the person's (Vp8Tuning).
            let vp8 = Vp8Tuning.forLane(carrier: lane.carrier,
                                        fps: params.vp8FPS ?? s.vp8FPS,
                                        batch: params.vp8BatchSize ?? s.vp8Batch)
            try rt.setVP8Options(vp8.fps, batchSize: vp8.batch)
        }
        if lane.transport == "seichannel" {
            // New in master: client-side SEI tuning (old API had no setter).
            try rt.setSEIOptions(params.seiFPS, batchSize: params.seiBatch,
                                 fragmentSize: params.seiFrag,
                                 ackTimeoutMillis: params.seiACK)
        }
        // #230 native control-stream liveness — same gentle values as before.
        try rt.setLivenessOptions(30_000, timeoutMillis: 10_000, failures: 3)
        // Settings → Routing: the core dials listed destinations itself.
        try rt.setDirectRules(s.directRules)
        // #436 wbstream account token → master's providerToken: set inside
        // `startLocked`, in the same critical section as `Start()`, so a probe
        // cannot slip its own token in between (#470).
        let (socksUser, socksPass) = socksCredentials(params, settings: s)
        try rt.setSocksPort(port)
        try rt.setSocksCredentials(socksUser, password: socksPass)
    }

    /// The credentials the SOCKS listener asks apps for.
    private static func socksCredentials(_ params: OlcrtcConnection,
                                         settings s: EngineStartSettings) -> (String, String) {
        s.localSocksAuthEnabled ? (s.localSocksUser, s.localSocksPass) : (params.socksUser, params.socksPass)
    }

    // MARK: Several lanes at once

    /// One runtime per lane, each on its own loopback port, joined on the port
    /// apps use: by the bond client when the server runs a bond endpoint
    /// (every connection over all lanes at once), else by the balancer (each
    /// connection to the next lane that is up). Every runtime takes the same
    /// credentials as the public port. Ready as soon as any lane is.
    private func startLanes(_ params: OlcrtcConnection, port: Int, settings s: EngineStartSettings) async throws {
        let lanes = params.lanes
        var ports: [Int] = []
        while ports.count < lanes.count {
            guard let free = PortAvailability.freeEphemeralPort() else {
                throw TunnelEngineError(L10n.pingNoFreePort.localized(), reason: .portBusy)
            }
            let p = Int(free)
            if p != port, !ports.contains(p) { ports.append(p) }
        }
        var runtimes: [MobileRuntime] = [runtime]
        for _ in 1..<lanes.count {
            guard let extra = MobileNew() else {
                throw TunnelEngineError("internal: MobileNew() returned nil", reason: .unknown)
            }
            runtimes.append(extra)
        }
        let startEpoch = lanesLock.withLock { () -> Int in
            laneRuntimes = Array(runtimes.dropFirst())
            return laneEpoch
        }
        await MainActor.run { LogStore.shared.log(.connection, L10n.lanesStarting_fmt.formatted(lanes.count)) }

        // A reconnect joins the rooms in turn (VPNConfig.laneRejoinOffset):
        // rooms that failed together are not all asked again in one burst.
        // The first lane starts now, the others while the wait below runs.
        let offsets: [TimeInterval] = runtimes.indices.map { i in
            s.isReconnect && i > 0 ? VPNConfig.laneRejoinOffset(rank: i - 1, random: .random(in: 0...1)) : 0
        }
        let lastStart = Date().addingTimeInterval(offsets.max() ?? 0)
        do {
            for (i, rt) in runtimes.enumerated() where offsets[i] == 0 {
                try Self.configure(rt, params: params, lane: lanes[i], port: ports[i], settings: s)
                try Self.startLocked(rt, token: Self.providerToken(params, carrier: lanes[i].carrier))
            }
        } catch {
            let raw = (error as NSError).localizedDescription
            stop()
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw)) }
            throw TunnelEngineError(Self.startErrorReason(raw, port: port),
                                    reason: HealthFailureMapper.reason(forRaw: raw))
        }
        await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartOK.localized(), code: .nativeStartOK) }
        for i in runtimes.indices where offsets[i] > 0 {
            let rt = runtimes[i], lane = lanes[i], lanePort = ports[i], wait = offsets[i]
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                // Not across a stop: the session it was meant for is gone. A
                // start that fails is the lane watch's to try again.
                self.lanesLock.withLock { () -> Void in
                    guard self.laneEpoch == startEpoch else { return }
                    do {
                        try OlcrtcEngine.configure(rt, params: params, lane: lane, port: lanePort, settings: s)
                        try OlcrtcEngine.startLocked(rt, token: OlcrtcEngine.providerToken(params, carrier: lane.carrier))
                    } catch {}
                }
            }
        }

        do {
            try Self.waitAnyReady(runtimes, timeoutMs: s.timeoutMs, holdUntil: lastStart)
        } catch {
            let raw = (error as NSError).localizedDescription
            stop()
            let noPeer = Self.isNoPeerWaitError(raw)
            await MainActor.run { LogStore.shared.log(.connection, L10n.waitReadyFailed_fmt.formatted(raw)) }
            throw TunnelEngineError(noPeer ? L10n.connectNoPeer.localized() : Self.startErrorReason(raw, port: port),
                                    reason: noPeer ? .noPeer : HealthFailureMapper.reason(forRaw: raw))
        }

        let endpoint = params.bond.flatMap { ServerBundle.split(endpoint: $0) }
        if let endpoint {
            let (user, pass) = Self.socksCredentials(params, settings: s)
            guard let client = BondNewClient(port, user, pass, params.key, endpoint.host, endpoint.port) else {
                stop()
                throw TunnelEngineError("internal: BondNewClient() returned nil", reason: .unknown)
            }
            for lanePort in ports {
                client.addLane(lanePort, user: user, pass: pass)
            }
            // Rooms on one conference host fail together: tell the bond, so its
            // backup is taken off that host (LaneGroup).
            for (i, lane) in lanes.enumerated() {
                let group = LaneGroup.key(carrier: lane.carrier, room: lane.roomID)
                if !group.isEmpty { client.setLaneGroup(i, group: group) }
            }
            // A bonded connection reaches a lane only as a CONNECT to the bond
            // server: the client decides what goes direct before it bonds.
            client.setDirectRules(s.directRules)
            do {
                try client.start()
            } catch {
                stop()
                throw TunnelEngineError(L10n.errorPortBusy_fmt.formatted(port), reason: .portBusy)
            }
            lanesLock.withLock { self.bondClient = client }
        } else {
            let balancer = LaneBalancer(lanePorts: ports.map { UInt16($0) },
                                        isUp: { runtimes[$0].state() == "running" })
            do {
                try await balancer.start(port: UInt16(port))
            } catch {
                stop()
                throw TunnelEngineError(L10n.errorPortBusy_fmt.formatted(port), reason: .portBusy)
            }
            lanesLock.withLock { self.balancer = balancer }
        }
        let watched = runtimes, watchedPorts = ports
        lanesLock.withLock {
            lanePortList = watchedPorts
            let epoch = laneEpoch
            laneWatch = Task.detached(priority: .utility) { [weak self] in
                // The lanes still to start in turn are not the watch's yet.
                let pending = lastStart.timeIntervalSinceNow
                if pending > 0 { try? await Task.sleep(for: .seconds(pending)) }
                await self?.watchLanes(watched, params: params, ports: watchedPorts, settings: s, epoch: epoch)
            }
        }
        let joined = endpoint != nil ? "bonded" : "taking turns"
        await MainActor.run {
            LogStore.shared.log(.connection, L10n.waitReadyOK.localized())
            LogStore.shared.log(.connection, "✓ SOCKS5 proxy ready on port \(port) — \(lanes.count) lanes, \(joined)",
                                code: .socksReady)  // OLC-1004
        }
    }

    /// Joins a lane again whenever its runtime has ended, waiting 2 s and then
    /// twice as long after each failed try (at most 2 min, each wait jittered),
    /// for as long as the session of `epoch` lasts. A lane that comes up starts
    /// the wait over. Each try is a whole WebRTC join, so a room that stays
    /// broken (an expired link) must not cost the battery one every few
    /// seconds; lanes that dropped together are joined again in turn
    /// (`VPNConfig.laneRejoinOffset`), never all at once.
    private func watchLanes(_ runtimes: [MobileRuntime], params: OlcrtcConnection, ports: [Int],
                            settings s: EngineStartSettings, epoch: Int) async {
        let lanes = params.lanes
        var delay = [TimeInterval](repeating: 0, count: runtimes.count)
        var due = [Date](repeating: .distantPast, count: runtimes.count)
        // Whether a lane that left its room has its first rejoin set yet.
        var rejoinSet = [Bool](repeating: false, count: runtimes.count)
        // When each lane was first seen still joining; nil once in its room.
        var joiningSince = [Date?](repeating: nil, count: runtimes.count)
        let joinLimit = VPNConfig.laneJoinLimit(timeoutMs: s.timeoutMs)
        var silence = LaneSilenceWatch()
        var outOfRoom = DeadLaneWatch()
        // Whether any lane was up at the last look: the session was ready, so
        // one was when the watch began.
        var anyWasUp = true
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.laneWatchInterval)
            // A bonded lane in its room that brings nothing in while the
            // others carry has lost the room (LaneSilenceWatch).
            var silent: Set<Int> = []
            if let client = lanesLock.withLock({ self.bondClient }),
               let rx = LaneSilenceWatch.receivedBytes(client.laneBytes()), rx.count == runtimes.count {
                silent = Set(silence.silentLanes(rx: rx, now: ProcessInfo.processInfo.systemUptime))
            }
            // A lane out of its room for long is told to the app, which looks
            // where that room is now (DeadLaneWatch).
            let up = runtimes.indices.map { i in
                runtimes[i].isRunning() && runtimes[i].state() == "running" && !silent.contains(i)
            }
            let dead = outOfRoom.deadLanes(up: up, now: ProcessInfo.processInfo.systemUptime)
            if !dead.isEmpty, lanesLock.withLock({ laneEpoch == epoch }) {
                await MainActor.run {
                    for lane in dead { Self.laneDeadObserver?(lane) }
                }
            }
            // Every lane down at once is the whole session's sign, not a lane's.
            let anyUp = up.contains(true)
            if anyWasUp, !anyUp, lanesLock.withLock({ laneEpoch == epoch }) {
                await MainActor.run { Self.lanesDownObserver?() }
            }
            anyWasUp = anyUp
            // The place in line of each lane found out of its room on this look.
            var rank = 0
            for i in runtimes.indices where i < lanes.count && i < ports.count {
                let rt = runtimes[i]
                if rt.isRunning() {
                    let inRoom = rt.state() == "running"
                    if inRoom, !silent.contains(i) {
                        delay[i] = 0
                        joiningSince[i] = nil
                        rejoinSet[i] = false
                        continue
                    }
                    if !inRoom {
                        // Still joining. A first join can wait forever (a room
                        // the server set up again under it): past the limit it
                        // is ended here and started afresh below.
                        let since = joiningSince[i] ?? Date()
                        joiningSince[i] = since
                        guard Date().timeIntervalSince(since) >= joinLimit else { continue }
                    }
                    // Never across a stop: lane 1 is the engine's own runtime,
                    // which a newer start reuses (laneRecycleLock).
                    let ended: Bool = laneRecycleLock.withLock {
                        guard lanesLock.withLock({ laneEpoch == epoch }), !Task.isCancelled else { return false }
                        try? rt.stop(Self.stopTimeoutMs)
                        return true
                    }
                    guard ended else { return }
                    let carrier = lanes[i].carrier
                    await MainActor.run {
                        let name = CarrierTransportMatrix.carrierLabel(carrier)
                        LogStore.shared.log(.connection, inRoom
                            ? L10n.laneSilent_fmt.formatted(i + 1, name)
                            : L10n.laneJoinStuck_fmt.formatted(i + 1, name))
                    }
                }
                joiningSince[i] = nil
                let now = Date()
                if !rejoinSet[i] {
                    rejoinSet[i] = true
                    due[i] = now.addingTimeInterval(VPNConfig.laneRejoinOffset(rank: rank, random: .random(in: 0...1)))
                    rank += 1
                }
                guard now >= due[i] else { continue }
                delay[i] = Self.nextLaneDelay(after: delay[i])
                due[i] = now.addingTimeInterval(VPNConfig.jitteredLaneDelay(delay[i], random: .random(in: 0...1)))
                let started: Bool? = lanesLock.withLock {
                    guard laneEpoch == epoch, !Task.isCancelled else { return nil }
                    do {
                        try Self.configure(rt, params: params, lane: lanes[i], port: ports[i], settings: s)
                        try Self.startLocked(rt, token: Self.providerToken(params, carrier: lanes[i].carrier))
                        return true
                    } catch {
                        return false
                    }
                }
                guard let started else { return }
                let carrier = lanes[i].carrier
                await MainActor.run {
                    let name = CarrierTransportMatrix.carrierLabel(carrier)
                    LogStore.shared.log(.connection, started
                        ? L10n.laneRejoining_fmt.formatted(i + 1, name)
                        : L10n.laneRejoinFailed_fmt.formatted(i + 1, name))
                }
            }
        }
    }

    /// PURE. The wait before the next try to join a lane again: 2 s, then
    /// doubling, at most 2 min.
    static func nextLaneDelay(after previous: TimeInterval) -> TimeInterval {
        min(max(previous * 2, 2), 120)
    }

    /// Returns once any runtime is ready; throws the last error when the
    /// time runs out or every runtime has stopped. Until `holdUntil` some
    /// runtimes may not have been started yet: none running is no verdict
    /// then.
    private static func waitAnyReady(_ runtimes: [MobileRuntime], timeoutMs: Int,
                                     holdUntil: Date = .distantPast) throws {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1_000)) / 1_000)
        var lastError: Error = TunnelEngineError(L10n.connectNoPeer.localized(), reason: .noPeer)
        while Date() < deadline {
            let holding = Date() < holdUntil
            var anyActive = false
            for rt in runtimes {
                if holding, !rt.isRunning() { continue }
                do {
                    try rt.waitReady(250)
                    return
                } catch {
                    lastError = error
                }
                if rt.isRunning() { anyActive = true }
            }
            if !anyActive {
                guard holding else { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw lastError
    }

    func ping(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let stored) = details else { return .failure(L10n.pingFailed.localized()) }
        let params = DeviceIdentity.resolving(stored)
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8 = Vp8Tuning.effective(carriers: [params.carrier],
                                      fps: params.vp8FPS ?? s.vp8FPS,
                                      batch: params.vp8BatchSize ?? s.vp8Batch)
        let vp8FPS   = vp8.fps
        let vp8Batch = vp8.batch
        let runtime = self.runtime
        return await Task.detached {
            // Probes are isolated on the Go side (probeConfig snapshots defaults;
            // never touches the live generation) — safe alongside a running tunnel.
            // #445 (audit fix 8): BUT the snapshot copies the SHARED runtime's
            // defaults and Ping overrides only provider/transport/room/device/key/
            // port — providerToken rides along from whatever the LAST start()
            // left behind (master mobile/probe.go), so probing a wbstream node
            // used the previous connection's token (or none before any connect).
            // Pin this record's own token first.
            // #470 was: a bare `runtime.setProviderToken(params.wbToken)` and the
            // claim that overlapping a concurrent start() was "a benign last-write
            // race" — it was not: Start() snapshots the defaults, so this write
            // landing between start()'s setter and its Start() gave the LIVE
            // session this node's token. Same lock as `startLocked`.
            Self.setTokenLocked(runtime, params.wbToken)
            var result: Int64 = -1
            do {
                try runtime.ping(
                    params.carrier, transportName: params.transport,
                    roomID: params.roomID, deviceID: params.clientID,
                    keyHex: params.key,
                    socksPort: Int(port), timeoutMillis: s.timeoutMs,
                    pingURL: s.pingURL,
                    vp8FPS: vp8FPS, vp8BatchSize: vp8Batch,
                    ret0_: &result)
            } catch {
                return PingOutcome.failure((error as NSError).localizedDescription)
            }
            guard result >= 0 else { return PingOutcome.failure(L10n.pingFailed.localized()) }
            return PingOutcome.success(ms: Int(result))
        }.value
    }

    func checkReady(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let stored) = details else { return .failure(L10n.pingFailed.localized()) }
        let params = DeviceIdentity.resolving(stored)
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8 = Vp8Tuning.effective(carriers: [params.carrier],
                                      fps: params.vp8FPS ?? s.vp8FPS,
                                      batch: params.vp8BatchSize ?? s.vp8Batch)
        let vp8FPS   = vp8.fps
        let vp8Batch = vp8.batch
        let runtime = self.runtime
        return await Task.detached {
            // #445 (audit fix 8): same token pinning as `ping` above — Check's
            // probe config inherits providerToken from the shared runtime defaults.
            // #470 was: `runtime.setProviderToken(params.wbToken)` — see `ping`.
            Self.setTokenLocked(runtime, params.wbToken)
            var result: Int64 = -1
            do {
                try runtime.check(
                    params.carrier, transportName: params.transport,
                    roomID: params.roomID, deviceID: params.clientID,
                    keyHex: params.key,
                    socksPort: Int(port), timeoutMillis: s.timeoutMs,
                    vp8FPS: vp8FPS, vp8BatchSize: vp8Batch,
                    ret0_: &result)
            } catch {
                return PingOutcome.failure((error as NSError).localizedDescription)
            }
            guard result >= 0 else { return PingOutcome.failure(L10n.pingFailed.localized()) }
            return PingOutcome.success(ms: Int(result))
        }.value
    }
}

/* NAMING CAUTION — verify against the generated Mobile.objc.h on the first CI
   bind (this machine cannot run gomobile). Expected gomobile spellings:
     MobileNew() -> MobileRuntime?                       (func New() *Runtime)
     runtime.setProvider(_:) throws                      (error-returning setters → throws)
     runtime.setSocksCredentials(_:password:) throws
     runtime.setVP8Options(_:batchSize:) throws
     runtime.setSEIOptions(_:batchSize:fragmentSize:ackTimeoutMillis:) throws
     runtime.setLivenessOptions(_:timeoutMillis:failures:) throws
     runtime.setDebug(_:) / setDeviceID(_:) / setProviderToken(_:)   (no error → non-throwing)
     runtime.start() throws / waitReady(_:) throws / stop(_:) throws
     runtime.state() -> String / isRunning() -> Bool
     runtime.check(_:transportName:roomID:deviceID:keyHex:socksPort:timeoutMillis:vp8FPS:vp8BatchSize:ret0_:) throws
     runtime.ping(_:transportName:roomID:deviceID:keyHex:socksPort:timeoutMillis:pingURL:vp8FPS:vp8BatchSize:ret0_:) throws
   Int64 results use the ret0_ out-param pattern; String params import as String?.
   SetResolver(*net.Resolver) is an unsupported type — gomobile SKIPS it with a
   warning; that is expected, not an error. */
