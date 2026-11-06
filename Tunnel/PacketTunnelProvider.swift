import Foundation
import Network
import NetworkExtension
import Mobile

// MARK: - PacketTunnelProvider (#vpn)
//
// The system-VPN provider (target olcrtc-tunnel, NSExtensionPrincipalClass).
// It runs the ENTIRE olcrtc Go core in the extension process — the app can be
// suspended while the tunnel runs, and NEPacketTunnelFlow packets arrive here —
// plus the tunstack tun2socks layer from the same Mobile.xcframework:
//
//   packetFlow.readPackets ──▶ TunstackTunnel.writePacket ──▶ lwIP ──▶
//   SOCKS5 CONNECT to 127.0.0.1:<socksPort> (the in-process core listener)
//   ──▶ olcrtc carrier ▶ … and back via TunWriter ──▶ packetFlow.writePackets
//
// Loop avoidance: iOS routes provider-process-originated sockets (pion
// ICE/DTLS, the core's protected DNS) to the underlying interface, NOT into
// this tunnel — so there are NO excludedRoutes and includeAllNetworks is
// NEVER set (it would pull our own traffic into the tunnel and loop).
//
// Memory: the extension lives under a ~50 MB jetsam cap. Before the core
// starts we set a 30 MiB Go soft memory limit + GC at 20%
// (OlcosTuneForNetworkExtension — the Go runtime is process-wide, so the knob
// from the olcos package covers the olcrtc core too); the core itself sizes
// its smux buffers for a phone (4 MiB / 512 KiB). Memory-pressure events
// trigger MobileFreeOSMemory.
//
// Engines: `VPNConfig.engine` selects the Go core. `olcrtc` is the path
// described above (MobileRuntime). `xray` swaps the core for olcos-core's
// VLESS · REALITY engine (XrayTunnelSession) — the same tunstack layer then
// dials ITS loopback SOCKS5 listener; everything from `TunstackNewTunnel` on
// is shared. Both packages are bound into one Mobile.xcframework and one Go
// runtime, so the memory knobs are process-wide whichever shim sets them.
//
// UDP: tunstack forwards TCP only, so the core's UDP relay is switched off
// here (rt.setUDP(false)) and no UDP crosses the tunnel.
// tunstack's dnstruncate answers UDP DNS with the TC bit → the OS resolver
// retries DNS over TCP:53 through the tunnel; all other UDP is dropped
// (QUIC falls back to TCP; mandatory-UDP apps do not work in VPN mode).
//
// NAMING CAUTION — this machine cannot run gomobile; verify the generated
// selector names against Mobile.objc.h on the first CI bind:
//   MobileNew() -> MobileRuntime?                      (mobile.New)
//   MobileSetLogWriter(MobileLogWriterProtocol?)       (core mobile/log.go)
//   OlcosTuneForNetworkExtension(Int64)                (olcos-core olcos.go)
//   MobileFreeOSMemory()                               (core mobile/memory.go)
//   TunstackNewTunnel(String?, Int, TunstackTunWriterProtocol?, NSErrorPointer) -> TunstackTunnel?
//   TunstackTunnel.writePacket(Data?) throws           (WritePacket([]byte) error)
//   TunstackTunnel.close() throws / rxBytes() -> Int64 / txBytes() -> Int64
//   TunstackTunWriterProtocol { func writePacket(_ p: Data?) }
//   runtime.set*(...) throws for error-returning Go setters; state()/isRunning()

final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Matches OlcrtcEngine.stopTimeoutMs — Runtime.Stop blocks until the
    /// generation's goroutine exits or this many ms pass.
    private static let stopTimeoutMs = 5_000

    /// Serialises start/stop/teardown so completion-handler callbacks and the
    /// system's stop cannot race the blocking Go calls.
    private let workQueue = DispatchQueue(label: "io.github.hotelk52339.olcrtc-ios.tunnel.work")

    private var runtime: MobileRuntime?          // olcrtc engine, one room
    private var xraySession: XrayTunnelSession?  // xray engine (exactly one engine is live)
    /// A bonded session's lanes and the bond client tunstack dials instead of
    /// a core (`doStartBonded`); `runtime` stays nil then.
    private var bondLanes: [BondLane] = []
    private var bondClient: BondClient?
    /// Joins a bonded session's lanes again (`superviseLanes`).
    private var laneSupervisor: DispatchSourceTimer?
    /// Which bonded lanes stopped bringing anything in (`superviseLanes`).
    private var laneSilence = LaneSilenceWatch()
    private var tunnel: TunstackTunnel?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var startedAt: Date?

    private let logBuffer = LogRingBuffer(capacity: 400)
    private let logCapture = ExtensionLogCapture()
    /// Keeps the widgets' on/off true while the app is suspended.
    private lazy var widgetReporter = TunnelWidgetReporter(queue: workQueue)

    /// Joins the rooms again when the session stops carrying or its network
    /// changes (VPNSessionRecovery). Like everything here, on workQueue.
    private var recovery = VPNSessionRecovery()
    private var pathMonitor: NWPathMonitor?
    /// The rejoin waiting for its backoff, or for a changed network to settle.
    private var pendingRejoin: DispatchWorkItem?
    /// A loss of the network waiting out `networkLossGrace`.
    private var pendingLoss: DispatchWorkItem?

    // MARK: Start

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let dict = proto.providerConfiguration,
              let config = VPNConfig(providerConfiguration: dict) else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        // boc #484: owner-selected app-only VPN launch (D14). The saved profile
        // deliberately omits credentials; external starts must explain how to
        // restore them, not report that the saved connection's room key is bad.
        guard config.hasCredentials else {
            completionHandler(NSError(
                domain: "io.github.hotelk52339.olcrtc-ios.tunnel",
                code: 48414,
                userInfo: [NSLocalizedDescriptionKey:
                    // #485: extension resources are isolated from the app's
                    // L10n tables; use its own localized bundle, never app state.
                    Self.localizedMessage("vpn.startRequiresApp", language: dict["uiLanguage"] as? String)]))
            return
        }
        // eoc #484
        // videochannel runs a real 1080p VP8 codec (~16 MiB decoder queue per
        // remote track) — it cannot fit the extension's memory cap. VPN mode
        // allows datachannel / vp8channel / seichannel only (the latter two
        // are header-wrapping fakes with no codec).
        guard config.isXray || config.transport != "videochannel" else {
            logBuffer.append("startTunnel rejected: videochannel transport exceeds the Network Extension memory budget")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        // boc #484: IPv6 is intentionally fail-closed in the packet pump.
        // #484 was: every accepted DNS setting was installed and could leave a
        // Connected device unable to resolve anything. Reject before starting
        // Go or installing routes; never remove ::/0 to make DNS appear to work.
        guard config.supportsPacketDNS else {
            logBuffer.append("startTunnel rejected: system DNS must be an IPv4 literal on port 53; IPv6 DNS remains supported for proxy/core resolution")
            // #485 was: generic configurationInvalid without an actionable cause.
            completionHandler(NSError(
                domain: "io.github.hotelk52339.olcrtc-ios.tunnel",
                code: 48422,
                userInfo: [NSLocalizedDescriptionKey:
                    Self.localizedMessage("vpn.unsupportedDNS", language: dict["uiLanguage"] as? String)]))
            return
        }
        // eoc #484
        workQueue.async {
            if config.isXray {
                self.doStartXray(config, completionHandler)
            } else {
                self.doStart(config, completionHandler)
            }
        }
    }

    // boc #488: the app's selected language can differ from the device language.
    // Pass only an allowlisted language code in nonsecret profile metadata;
    // old profiles without it retain the extension's normal system localization.
    private static func localizedMessage(_ key: String, language: String?) -> String {
        var resources = Bundle.main
        if let language, ["en", "ru", "fr"].contains(language),
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            resources = localized
        }
        return resources.localizedString(forKey: key, value: nil, table: nil)
    }
    // eoc #488

    private func doStart(_ config: VPNConfig, _ completionHandler: @escaping (Error?) -> Void) {
        // Memory knob FIRST: the GC limit should precede any real allocation.
        OlcosTuneForNetworkExtension(30 << 20)       // 30 MiB Go soft limit + GC 20%

        // Core log lines -> in-extension ring buffer (served via
        // handleAppMessage "logs"; no App Group in v1, by design).
        // Capture the buffer, not self: logCapture is retained by the Go side
        // via MobileSetLogWriter and must not create a cycle through self.
        logCapture.onLog = { [buffer = logBuffer] line in buffer.append(line) }
        MobileSetLogWriter(logCapture)

        if config.isBonded {
            doStartBonded(config, completionHandler)
            return
        }

        guard let rt = MobileNew() else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        do {
            try configure(rt, config, carrier: config.carrier, transport: config.transport,
                          room: config.roomID, port: config.socksPort)
        } catch {
            logBuffer.append("configure failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        do {
            try rt.start()                          // spawns the run goroutine
        } catch {
            logBuffer.append("start failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }
        runtime = rt

        // #470: a stop that arrived before this point wins — do not wait at all.
        guard beginWait(on: rt) else {
            logBuffer.append("start abandoned: stopTunnel arrived before the carrier answered")
            try? rt.stop(Self.stopTimeoutMs)
            runtime = nil
            completionHandler(NEVPNError(.connectionFailed))
            return
        }
        do {
            defer { endWait() }   // #470
            // Blocks until the carrier rendezvoused and the SOCKS listener is
            // up (0 -> core default 8 s). Safe to block: we are on workQueue —
            // and interruptible, see `interruptPendingStart` (#470).
            try rt.waitReady(config.waitReadyTimeoutMs)
        } catch {
            logBuffer.append("waitReady failed: \(error.localizedDescription)")
            try? rt.stop(Self.stopTimeoutMs)
            runtime = nil
            completionHandler(error)
            return
        }

        attachTunnelAndSettings(config, completionHandler)
    }

    /// The one setter sequence every runtime here gets, for one room on one
    /// loopback port. Mirrors OlcrtcEngine.configure (App/Core/TunnelEngine
    /// .swift); master's setters VALIDATE and THROW — surface the Go error.
    private func configure(_ rt: MobileRuntime, _ config: VPNConfig, carrier: String, transport: String,
                           room: String, port: Int, vp8FPS: Int? = nil, vp8Batch: Int? = nil) throws {
        try rt.setDNS(config.dns)
        try rt.setProvider(carrier)             // telemost | vkcalls | salutejazz | mtslink | wbstream | jitsi
        try rt.setTransport(transport)
        try rt.setRoom(room)                    // ID or URL, verbatim
        rt.setDeviceID(config.clientID)
        try rt.setKey(config.keyHex)
        // A bonded lane's own numbers win over the session's (an MTS Link room runs at 60 / 64, the others at
        // the person's); nil overrides fall through to the core defaults (30 / 64).
        if transport == "vp8channel", let fps = vp8FPS ?? config.vp8FPS, let batch = vp8Batch ?? config.vp8Batch {
            try rt.setVP8Options(fps, batchSize: batch)
        }
        if transport == "seichannel" {
            try rt.setSEIOptions(config.seiFPS, batchSize: config.seiBatch,
                                 fragmentSize: config.seiFrag,
                                 ackTimeoutMillis: config.seiACK)
        }
        // Same gentle liveness values as proxy mode (#230).
        try rt.setLivenessOptions(30_000, timeoutMillis: 10_000, failures: 3)
        // Settings → Routing: this process dials listed destinations itself,
        // and a provider's own sockets never enter its tunnel.
        try rt.setDirectRules(config.directRules)
        // Unconditional: empty clears a previous token (same rule as #436).
        // Only WB Stream takes one; VK Calls refuses any (see
        // OlcrtcEngine.providerToken).
        rt.setProviderToken(carrier == "wbstream" ? config.wbToken : "")
        // tunstack forwards TCP only; the core's UDP relay would idle in a
        // process that has no memory to spare for it.
        rt.setUDP(false)
        // Loopback listener. NO SOCKS credentials: the core requires them
        // only for non-loopback binds, and the tunstack SOCKS client
        // deliberately sends none.
        // #470 was: "private to this process" — loopback is DEVICE-wide on
        // iOS: any app can dial 127.0.0.1:<socksPort> while the tunnel is
        // up (and gains nothing by it — every app's traffic already rides
        // the tunnel), and a listener another process already holds on
        // that port fails the bind inside the run goroutine, which
        // `waitReady` below reports with the Go text ("address already in
        // use") into the ring buffer.
        try rt.setSocksListenHost("127.0.0.1")
        try rt.setSocksPort(port)
    }

    // MARK: Start (bonded)

    /// A whole-server connection bonded here (Settings → VPN bonding, a trial):
    /// one runtime per lane on its own loopback port just above the tunnel's,
    /// and the bond client on the port tunstack dials, carrying every
    /// connection over all lanes to the server's bond endpoint. Up as soon as
    /// any lane is. A lane that cannot start, or whose runtime ends later,
    /// keeps its port and its place with the client, and the supervisor
    /// starts it again. A stop that arrives meanwhile wins, as on the single
    /// path (#470).
    private func doStartBonded(_ config: VPNConfig, _ completionHandler: @escaping (Error?) -> Void) {
        bondLanes = config.lanes.enumerated().map { index, lane in
            BondLane(lane: lane, port: config.socksPort + 1 + index)
        }
        var started: [MobileRuntime] = []
        for index in bondLanes.indices {
            if let failure = startLane(index, config) {
                logBuffer.append("lane \(index + 1) (\(bondLanes[index].lane.carrier)) did not start: \(failure)")
            } else if let rt = bondLanes[index].rt {
                started.append(rt)
            }
        }
        guard !started.isEmpty else {
            stopCoreLocked()
            completionHandler(NEVPNError(.connectionFailed))
            return
        }
        logBuffer.append("bonding \(bondLanes.count) lanes, \(started.count) started")

        let timeout = TimeInterval(config.waitReadyTimeoutMs > 0 ? config.waitReadyTimeoutMs : 8_000) / 1_000
        let deadline = Date().addingTimeInterval(timeout)
        var ready = false
        var abandoned = false
        waiting: while Date() < deadline {
            var alive = false
            for rt in started {
                guard beginWait(on: rt) else {
                    abandoned = true
                    break waiting
                }
                let up = (try? rt.waitReady(250)) != nil
                endWait()
                if up {
                    ready = true
                    break waiting
                }
                alive = alive || rt.isRunning()
            }
            if !alive { break }
        }
        guard ready, !abandoned else {
            logBuffer.append(abandoned ? "start abandoned: stopTunnel arrived before a lane answered"
                                       : "no lane answered in time")
            stopCoreLocked()
            completionHandler(NEVPNError(.connectionFailed))
            return
        }

        guard let colon = config.bond.lastIndex(of: ":"),
              let bondPort = Int(config.bond[config.bond.index(after: colon)...]),
              let client = BondNewClient(config.socksPort, "", "", config.keyHex,
                                         String(config.bond[..<colon]), bondPort) else {
            logBuffer.append("bond client: bad endpoint \(config.bond)")
            stopCoreLocked()
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        // Every lane, up or not, in the config's order: the client calls a
        // lane that is down again whenever a connection needs it, so one the
        // supervisor brings back carries again, and each lane keeps its
        // number on both sides (laneBytes, the server's log).
        for lane in bondLanes {
            client.addLane(lane.port, user: "", pass: "")
        }
        // Rooms on one conference host fail together: tell the bond, so its
        // backup is taken off that host (LaneGroup).
        for (i, lane) in bondLanes.enumerated() {
            let group = LaneGroup.key(carrier: lane.lane.carrier, room: lane.lane.room)
            if !group.isEmpty { client.setLaneGroup(i, group: group) }
        }
        // The extension has about 50 MB for everything it runs (the Go core,
        // lwip, the tunnel buffers): ask the bond for less than its 8 MiB
        // default, half of it toward the lanes.
        client.setMemoryBudget(4 << 20)
        // A bonded connection reaches a lane only as a CONNECT to the bond
        // server: the client decides what goes direct before it bonds.
        client.setDirectRules(config.directRules)
        do {
            try client.start()
        } catch {
            logBuffer.append("bond client failed: \(error.localizedDescription)")
            stopCoreLocked()
            completionHandler(error)
            return
        }
        bondClient = client
        startLaneSupervisor(config)
        attachTunnelAndSettings(config, completionHandler)
    }

    /// One lane of a bonded session: its room, its loopback port (fixed for
    /// the session, and the bond client's from the start), its runtime — kept
    /// while the lane is down — and the supervisor's wait before it tries the
    /// lane again.
    private struct BondLane {
        let lane: VPNConfig.Lane
        let port: Int
        var rt: MobileRuntime? = nil
        var delay: TimeInterval = 0
        /// The next try's earliest time, on the `systemUptime` clock.
        var due: TimeInterval = 0
        /// When the supervisor first saw the lane still joining, same clock;
        /// nil once it is in its room.
        var joiningSince: TimeInterval? = nil
        /// Whether the lane, out of its room, has its first rejoin set yet.
        var rejoinSet = false
    }

    /// Configures and starts lane `index` on its port, with a new runtime when
    /// it has none yet; nil once it started, else why it did not. Must run on
    /// workQueue.
    private func startLane(_ index: Int, _ config: VPNConfig) -> String? {
        if bondLanes[index].rt == nil { bondLanes[index].rt = MobileNew() }
        guard let rt = bondLanes[index].rt else { return "MobileNew() returned nil" }
        let lane = bondLanes[index].lane
        do {
            try configure(rt, config, carrier: lane.carrier, transport: lane.transport,
                          room: lane.room, port: bondLanes[index].port,
                          vp8FPS: lane.vp8FPS, vp8Batch: lane.vp8Batch)
            try rt.start()
            return nil
        } catch {
            try? rt.stop(Self.stopTimeoutMs)
            return error.localizedDescription
        }
    }

    /// How often the supervisor looks at the lanes; proxy mode's lane watch
    /// does the same (OlcrtcEngine.laneWatchInterval).
    private static let laneWatchInterval: TimeInterval = 3

    /// The core walks its room once and leaves retrying to the host: without
    /// this, a lane that dropped out would stay out for the rest of the
    /// session. It joins such a lane again, as proxy mode's lane watch does
    /// (OlcrtcEngine.watchLanes), from a timer on workQueue — no thread or
    /// goroutine of its own. `stopCoreLocked` cancels it.
    private func startLaneSupervisor(_ config: VPNConfig) {
        laneSupervisor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + Self.laneWatchInterval, repeating: Self.laneWatchInterval)
        timer.setEventHandler { [weak self] in self?.superviseLanes(config) }
        timer.resume()
        laneSupervisor = timer
    }

    /// One look at the lanes, on workQueue. A lane in its room starts its wait
    /// over; one whose runtime has ended is started again once its wait is
    /// up, and the next wait is twice as long (2 s, at most 2 min — each try
    /// is a whole WebRTC join — jittered). Lanes that dropped together are
    /// joined again in turn (VPNConfig.laneRejoinOffset), as proxy mode's
    /// lane watch does. Nothing starts once a stop has begun
    /// (`stopArrivedEarly`): the teardown queued behind this would only have
    /// to stop it again.
    private func superviseLanes(_ config: VPNConfig) {
        // No network, or every lane's rejoin on its way: a try now would only
        // fail and lengthen the lane's next wait.
        guard !recovery.offline, pendingRejoin == nil else { return }
        let joinLimit = VPNConfig.laneJoinLimit(timeoutMs: config.waitReadyTimeoutMs)
        // A lane in its room that brings nothing in while the others carry
        // has lost the room (LaneSilenceWatch).
        var silent: Set<Int> = []
        if let client = bondClient, let rx = LaneSilenceWatch.receivedBytes(client.laneBytes()),
           rx.count == bondLanes.count {
            silent = Set(laneSilence.silentLanes(rx: rx, now: ProcessInfo.processInfo.systemUptime))
        }
        // The place in line of each lane found out of its room on this look.
        var rank = 0
        for index in bondLanes.indices {
            let now = ProcessInfo.processInfo.systemUptime
            if let rt = bondLanes[index].rt, rt.isRunning() {
                let inRoom = rt.state() == "running"
                if inRoom, !silent.contains(index) {
                    bondLanes[index].delay = 0
                    bondLanes[index].joiningSince = nil
                    bondLanes[index].rejoinSet = false
                    continue
                }
                if !inRoom {
                    // Still joining. A first join can wait forever (a room the
                    // server set up again under it): past the limit it is ended
                    // here and started afresh below.
                    let since = bondLanes[index].joiningSince ?? now
                    bondLanes[index].joiningSince = since
                    guard now - since >= joinLimit else { continue }
                }
                startLock.lock(); let stopping = stopArrivedEarly; startLock.unlock()
                if stopping { return }
                logBuffer.append(inRoom
                    ? "lane \(index + 1) (\(bondLanes[index].lane.carrier)) brought nothing in for \(Int(LaneSilenceWatch.limit)) s: joining it again"
                    : "lane \(index + 1) (\(bondLanes[index].lane.carrier)) still joining after \(Int(joinLimit)) s: joining it again")
                try? rt.stop(Self.stopTimeoutMs)
            }
            bondLanes[index].joiningSince = nil
            if !bondLanes[index].rejoinSet {
                bondLanes[index].rejoinSet = true
                bondLanes[index].due = now + VPNConfig.laneRejoinOffset(rank: rank, random: .random(in: 0...1))
                rank += 1
            }
            guard now >= bondLanes[index].due else { continue }
            startLock.lock(); let stopping = stopArrivedEarly; startLock.unlock()
            if stopping { return }
            bondLanes[index].delay = VPNConfig.nextLaneDelay(after: bondLanes[index].delay)
            bondLanes[index].due = now + VPNConfig.jitteredLaneDelay(bondLanes[index].delay, random: .random(in: 0...1))
            let name = "lane \(index + 1) (\(bondLanes[index].lane.carrier))"
            if let failure = startLane(index, config) {
                logBuffer.append("\(name) did not start: \(failure)")
            } else {
                logBuffer.append("\(name) rejoining")
            }
        }
    }

    // MARK: Start (xray engine)

    /// The olcos-core counterpart of `doStart`: no carrier rendezvous, so no
    /// `waitReady` — `engine.start` returns with the listener bound (or with the
    /// core's error). A stop that raced the start is honoured right after.
    private func doStartXray(_ config: VPNConfig, _ completionHandler: @escaping (Error?) -> Void) {
        // Same process-wide Go knobs as the olcrtc path (one Go runtime).
        OlcosTuneForNetworkExtension(30 << 20)       // 30 MiB Go soft limit + GC 20%

        guard let session = XrayTunnelSession(logBuffer: logBuffer) else {
            logBuffer.append("xray: OlcosNew() returned nil — olcos package missing from Mobile.xcframework")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        do {
            try session.start(link: config.xrayLink, socksPort: config.socksPort, direct: config.directRules)
        } catch {
            logBuffer.append("xray start failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }
        xraySession = session

        // #470 analogue: `interruptPendingStart` had nothing to interrupt (the
        // start is synchronous), but the flag it sets still means "do not bring
        // the tunnel up".
        startLock.lock(); let abandoned = stopArrivedEarly; startLock.unlock()
        if abandoned {
            logBuffer.append("start abandoned: stopTunnel arrived while the xray engine was starting")
            session.stop()
            xraySession = nil
            completionHandler(NEVPNError(.connectionFailed))
            return
        }
        attachTunnelAndSettings(config, completionHandler)
    }

    // MARK: Start (shared tail)

    /// Everything after the loopback SOCKS5 listener is up — identical for both
    /// engines: tun2socks, OS network settings, watchers, pump.
    private func attachTunnelAndSettings(_ config: VPNConfig, _ completionHandler: @escaping (Error?) -> Void) {
        // tun2socks against the now-ready loopback listener.
        let writer = FlowWriter(flow: packetFlow)
        var bindError: NSError?
        guard let tun = TunstackNewTunnel("127.0.0.1", config.socksPort, writer, &bindError) else {
            let error = bindError ?? NEVPNError(.connectionFailed) as NSError
            logBuffer.append("tunstack failed: \(error.localizedDescription)")
            stopCoreLocked()
            completionHandler(error)
            return
        }
        tunnel = tun

        // #470 was: `config.dnsHost` — the core's resolver, which the OS's DNS
        // then reached THROUGH the tunnel from the VPS; a carrier-internal
        // preset answered nothing from there. `systemDNS` is the app's choice
        // for this path (VPNConfig.systemResolver).
        setTunnelNetworkSettings(Self.makeSettings(dnsHost: config.systemDNSHost)) { [weak self] settingsError in
            guard let self else {
                completionHandler(NEVPNError(.connectionFailed))
                return
            }
            self.workQueue.async {
                if let settingsError {
                    self.logBuffer.append("setTunnelNetworkSettings failed: \(settingsError.localizedDescription)")
                    self.teardownLocked()
                    completionHandler(settingsError)
                    return
                }
                self.startedAt = Date()
                self.installMemoryPressureHandler()
                // #484 was: startLivenessWatch() only sampled isRunning.
                self.recovery = VPNSessionRecovery()
                self.startLivenessWatch(config: config)
                self.startPathWatch(config: config)
                self.startPacketPump()
                self.logBuffer.append("tunnel up: \(config.engine) \(config.carrier)/\(config.transport), socks 127.0.0.1:\(config.socksPort)")
                self.widgetReporter.tunnelUp()
                completionHandler(nil)
            }
        }
    }

    // MARK: Network settings

    static func makeSettings(dnsHost: String) -> NEPacketTunnelNetworkSettings {
        // tunnelRemoteAddress is a placeholder — a WebRTC carrier has no
        // stable remote IP. 198.18.0.0/24 is the RFC 2544 benchmark range
        // (collision-free with real LANs).
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]        // 0.0.0.0/0
        // NO excludedRoutes (provider-own sockets bypass the tunnel on iOS)
        // and NEVER includeAllNetworks (would loop our own carrier traffic).
        settings.ipv4Settings = ipv4
        // boc #469 was: no ipv6Settings at all — "v1 is IPv4-only: on v6-capable
        // networks IPv6 traffic BYPASSES the tunnel". On a dual-stack carrier
        // (the norm here) every host with an AAAA record was reached DIRECTLY
        // from the real address while the hero said "everything on this
        // device". Claim the v6 default route so that traffic enters the tunnel
        // — where the pump drops it (AF_INET only) — instead of leaking. A
        // blackhole is honest; a bypass is not. ULA address, RFC 4193.
        let ipv6 = NEIPv6Settings(addresses: ["fd6f:6c63:7274:6300::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]        // ::/0
        settings.ipv6Settings = ipv6
        // eoc #469
        settings.dnsSettings = NEDNSSettings(servers: [dnsHost])  // host only, e.g. "8.8.8.8"
        settings.mtu = NSNumber(value: 1500)
        return settings
    }

    // MARK: Packet pump (OS -> lwIP)

    private func startPacketPump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            // boc #470: hop onto workQueue — `tunnel` is written there by
            // `teardownLocked`, and this completion runs on the flow's own
            // queue. Reading it here raced the teardown: a stale reference
            // re-armed the pump against a device that was already closed (its
            // `writePacket` failing into `try?`), and it was a Swift data race
            // on a class reference. On the queue, "nil ⇒ stop" is exact.
            // #470 was: guard let self, let tunnel = self.tunnel else { return }
            self.workQueue.async {
                guard let tunnel = self.tunnel else { return }   // stops the pump after teardown
                for (index, packet) in packets.enumerated() {
                    // AF_INET only: IPv6 enters the tunnel (#469 claims ::/0) and
                    // is dropped here — a blackhole, never a bypass.
                    if index < protocols.count, protocols[index].int32Value == AF_INET {
                        try? tunnel.writePacket(packet)
                    }
                }
                self.startPacketPump()
            }
            // eoc #470
        }
    }

    // MARK: Memory pressure

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: workQueue)
        source.setEventHandler { [weak self] in
            self?.logBuffer.append("memory pressure: releasing Go heap to the OS")
            MobileFreeOSMemory()   // process-wide; OlcosFreeOSMemory() would be the same call
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: Stop

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        interruptPendingStart()   // #470: unblock a start still waiting on the carrier
        workQueue.async {
            self.logBuffer.append("stopTunnel: reason \(reason.rawValue)")
            self.teardownLocked()
            completionHandler()
        }
    }

    // boc #470: a stop that arrives while `doStart` is blocked in `waitReady`
    // (up to the user's start timeout — 600 s at the clamp) used to queue
    // BEHIND it on workQueue, together with every app message. "Cancel" a few
    // seconds into a connect against a dead room left the system VPN icon on
    // "connecting" for the rest of that timeout, and a carrier that answered
    // late brought the tunnel UP with the app already showing Disconnected.
    // `Runtime.Stop` cancels the generation, and `WaitReady` returns as soon as
    // the run goroutine exits (ErrStoppedBeforeReady — mobile/runtime.go), so
    // the stop is issued straight away, off the queue, against the runtime the
    // wait holds; the queued teardown then finds a stopped runtime. Lock-
    // guarded: `stopTunnel` runs on the system's thread, not on workQueue.
    private let startLock = NSLock()
    /// The runtime `doStart` is blocked on, while it is.
    private var waitingRuntime: MobileRuntime?
    /// A stop arrived before the wait began (or while it ran) — the start must
    /// not proceed. Cleared by `teardownLocked` so a later start is unaffected.
    private var stopArrivedEarly = false

    /// Registers the runtime a wait is about to block on. False ⇒ a stop
    /// already arrived, and the caller must not wait at all.
    private func beginWait(on rt: MobileRuntime) -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        if stopArrivedEarly { return false }
        waitingRuntime = rt
        return true
    }

    private func endWait() {
        startLock.lock()
        waitingRuntime = nil
        startLock.unlock()
    }

    /// Called from `stopTunnel` before it queues the teardown. The bounded
    /// `stop` runs on a global queue: it blocks up to `stopTimeoutMs`, and the
    /// system's callback thread must not.
    private func interruptPendingStart() {
        startLock.lock()
        stopArrivedEarly = true
        let rt = waitingRuntime
        startLock.unlock()
        guard let rt else { return }
        DispatchQueue.global(qos: .userInitiated).async { try? rt.stop(Self.stopTimeoutMs) }
    }
    // eoc #470

    /// Must run on workQueue. Order matters: close the tun2socks device first
    /// (releases the lwIP per-process singleton and ends the pump), then stop
    /// the Go runtime (blocks up to stopTimeoutMs for the WebRTC teardown).
    // boc #484
    // #484 was: #469 inferred liveness from rt.isRunning() every 5 s. Upstream
    // keeps the run goroutine AND SOCKS listener alive after exhausted handshake
    // retries (internal/client/link.go), so that never detects a stuck session.
    // Runtime exit is still fatal, but only an actual SOCKS->remote DNS exchange
    // resets the data-path failure streak. No URLSession direct fallback, no
    // second runtime, no activity-byte heuristic, no overlapping probes.
    private var livenessTimer: DispatchSourceTimer?
    private var livenessProbe: SOCKSDataPathProbe?
    private var livenessGeneration = UUID()
    private var dataPathHealth = VPNDataPathHealth()

    /// `grace` is the wait before the first probe: the start's, or a rejoin's
    /// shorter one.
    private func startLivenessWatch(config: VPNConfig, grace: TimeInterval = VPNDataPathHealth.startupGrace) {
        livenessTimer?.cancel()
        livenessGeneration = UUID()
        let generation = livenessGeneration
        livenessProbe?.cancel()
        livenessProbe = nil
        dataPathHealth = VPNDataPathHealth()
        let graceEnds = ProcessInfo.processInfo.systemUptime + grace
        let joinLimit = VPNConfig.laneJoinLimit(timeoutMs: config.waitReadyTimeoutMs)
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        var nextProbeAt = graceEnds
        // Since when the core has been joining (a rejoin, or every lane at once).
        var joiningSince: TimeInterval?
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.livenessGeneration,
                  let core = self.coreStatus() else { return }
            if !core.running {
                // was: the tunnel was cancelled at once.
                self.logBuffer.append("core stopped (\(core.state))")
                self.sessionFailed(config)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            // Still joining: no probe can pass yet, and a failed one would
            // only cut the join short. It gets the start's budget, as the
            // first join did.
            guard core.state == "running" else {
                let since = joiningSince ?? now
                joiningSince = since
                if now - since >= joinLimit {
                    self.logBuffer.append("core still joining after \(Int(joinLimit)) s")
                    self.sessionFailed(config)
                }
                return
            }
            joiningSince = nil
            guard now >= nextProbeAt, self.livenessProbe == nil else { return }
            nextProbeAt = now + VPNDataPathHealth.interval
            guard let probe = SOCKSDataPathProbe(port: config.socksPort,
                                                dnsHost: config.systemDNSHost, queue: self.workQueue) else {
                self.failLiveness()
                return
            }
            self.livenessProbe = probe
            probe.start(timeout: VPNDataPathHealth.timeout) { [weak self] success in
                guard let self, generation == self.livenessGeneration else { return }
                self.livenessProbe = nil
                if success {
                    self.recovery.carried(now: ProcessInfo.processInfo.systemUptime)
                    if self.reasserting {
                        self.logBuffer.append("data path back")
                        self.reasserting = false
                    }
                } else {
                    self.logBuffer.append("data-path probe failed (SOCKS TCP DNS)")
                }
                if self.dataPathHealth.record(success: success) {
                    // was: the tunnel was cancelled here.
                    self.logBuffer.append("data path unavailable after bounded retries")
                    self.sessionFailed(config)
                } else if !success {
                    // A miss is confirmed within seconds, not a whole interval later.
                    nextProbeAt = ProcessInfo.processInfo.systemUptime
                        + VPNDataPathHealth.nextProbeDelay(failures: self.dataPathHealth.failures)
                }
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    /// Ends the watch: none of its ticks or probes reports any more.
    private func stopLivenessWatch() {
        // FIRST: cancelling an outstanding probe completes it synchronously.
        livenessGeneration = UUID()
        livenessTimer?.cancel()
        livenessTimer = nil
        livenessProbe?.cancel()
        livenessProbe = nil
    }

    // MARK: Recovery

    /// The session stopped carrying, or its core ended, with a network there:
    /// the rooms are joined again under the shared policy, for as long as the
    /// VPN is on (VPNSessionRecovery).
    private func sessionFailed(_ config: VPNConfig) {
        stopLivenessWatch()
        // The network went meanwhile: its return joins the rooms (startPathWatch).
        if recovery.offline { return }
        let attempt = recovery.attempts
        let delay = recovery.afterFailure()
        logBuffer.append(VPNSessionRecovery.tryNote(attempt: attempt, delay: delay))
        scheduleRejoin(after: delay, config: config)
    }

    /// Follows the phone's network while the tunnel is up. The provider's own
    /// sockets bypass its tunnel, so this is the Wi-Fi or cellular path the
    /// rooms run over.
    private func startPathWatch(config: VPNConfig) {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor, self.pathMonitor === monitor, self.tunnel != nil else { return }
            let primary = Self.primaryInterface(of: path)
            // `.requiresConnection` is a network that comes up on use (a
            // cellular radio waking): online. A usable path without a Wi-Fi,
            // cellular or wired interface says nothing about the rooms' one.
            let online = path.status != .unsatisfied
            if online, primary == nil { return }
            guard online else {
                // Held back: a blip changes nothing, and the policy sees the
                // loss only once it outlasts the grace. The data-path probes
                // go on meanwhile and catch rooms the blip did end.
                guard self.pendingLoss == nil, !self.recovery.offline else { return }
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.tunnel != nil else { return }
                    self.pendingLoss = nil
                    self.applyPath(online: false, primary: nil, config: config)
                }
                self.pendingLoss = item
                self.workQueue.asyncAfter(deadline: .now() + Self.networkLossGrace, execute: item)
                return
            }
            // Back within the grace: the policy never saw the loss, so the same
            // interface is no change and another one is a move.
            self.pendingLoss?.cancel()
            self.pendingLoss = nil
            self.applyPath(online: true, primary: primary, config: config)
        }
        monitor.start(queue: workQueue)
        pathMonitor = monitor
    }

    /// A network gone for less than this is not acted on, as in proxy mode
    /// (TunnelManager.networkLossGrace).
    private static let networkLossGrace: TimeInterval = 8

    private func applyPath(online: Bool, primary: NWInterface.InterfaceType?, config: VPNConfig) {
        switch recovery.pathChanged(satisfied: online, primary: primary) {
        case .none:
            break
        case .hold:
            logBuffer.append("network lost: the tunnel holds until one is back")
            pendingRejoin?.cancel()
            pendingRejoin = nil
            stopLivenessWatch()
            reasserting = true
        case .rejoin:
            let network = primary.map { String(describing: $0) } ?? "changed"
            logBuffer.append("network \(network): joining the rooms again")
            scheduleRejoin(after: ReconnectPolicy.networkSettle(random: .random(in: 0...1)), config: config)
        }
    }

    /// The interface the phone's traffic leaves by, past this tunnel and any
    /// other virtual one.
    private static func primaryInterface(of path: Network.NWPath) -> NWInterface.InterfaceType? {
        let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        return path.availableInterfaces.first { physical.contains($0.type) }?.type
    }

    /// Joins the rooms again after `delay`, in place of a rejoin already
    /// waiting. No probe runs meanwhile, and the system shows the VPN
    /// reconnecting until a probe goes through.
    private func scheduleRejoin(after delay: TimeInterval, config: VPNConfig) {
        pendingRejoin?.cancel()
        stopLivenessWatch()
        reasserting = true
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRejoin = nil
            self.rejoin(config)
        }
        pendingRejoin = item
        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Joins the session's rooms again on the same loopback ports, under the
    /// tunnel, which stays up: tunstack's next dial reaches the new session.
    /// Nothing once a stop has begun.
    private func rejoin(_ config: VPNConfig) {
        startLock.lock(); let stopping = stopArrivedEarly; startLock.unlock()
        guard !stopping, tunnel != nil, !recovery.offline else { return }
        if let rt = runtime {
            try? rt.stop(Self.stopTimeoutMs)
            MobileFreeOSMemory()
            do {
                try configure(rt, config, carrier: config.carrier, transport: config.transport,
                              room: config.roomID, port: config.socksPort)
                try rt.start()
            } catch {
                // The watch finds the core stopped and counts the try.
                logBuffer.append("rejoin failed: \(error.localizedDescription)")
            }
        } else if !bondLanes.isEmpty {
            let lanes = bondLanes.compactMap(\.rt)
            if !lanes.isEmpty {
                DispatchQueue.concurrentPerform(iterations: lanes.count) { try? lanes[$0].stop(Self.stopTimeoutMs) }
            }
            MobileFreeOSMemory()
            // Every lane starts over: none is silent for the time it was down.
            laneSilence = LaneSilenceWatch()
            // The first lane now, the others in turn from the supervisor
            // (VPNConfig.laneRejoinOffset): rooms that failed together are
            // not all asked again in one burst.
            let now = ProcessInfo.processInfo.systemUptime
            for index in bondLanes.indices {
                bondLanes[index].delay = 0
                bondLanes[index].joiningSince = nil
                bondLanes[index].rejoinSet = true
                bondLanes[index].due = index == 0
                    ? 0 : now + VPNConfig.laneRejoinOffset(rank: index - 1, random: .random(in: 0...1))
            }
            if !bondLanes.isEmpty, let failure = startLane(0, config) {
                logBuffer.append("lane 1 (\(bondLanes[0].lane.carrier)) did not start: \(failure)")
            }
        } else if let session = xraySession {
            do {
                try session.start(link: config.xrayLink, socksPort: config.socksPort, direct: config.directRules)
            } catch {
                logBuffer.append("xray rejoin failed: \(error.localizedDescription)")
            }
        }
        startLivenessWatch(config: config, grace: VPNSessionRecovery.rejoinGrace)
    }

    /// (running, state) of whichever core is live; nil when none is. A bonded
    /// session runs for as long as the supervisor calls its lanes back: every
    /// lane down at one tick (a network change) is not its end, and the
    /// data-path probe says when nothing carries any more. It reads "running"
    /// while any lane is in its room.
    private func coreStatus() -> (running: Bool, state: String)? {
        if let rt = runtime { return (rt.isRunning(), rt.state()) }
        if !bondLanes.isEmpty {
            let states = bondLanes.compactMap(\.rt).map { $0.state() }
            return (true, states.contains("running") ? "running" : "connecting")
        }
        if let x = xraySession { return (x.isRunning, x.state) }
        return nil
    }

    /// Stops and releases whichever core is live. Must run on workQueue.
    private func stopCoreLocked() {
        // First, so no lane starts again while the others stop.
        laneSupervisor?.cancel()
        laneSupervisor = nil
        bondClient?.stop()
        bondClient = nil
        // Every lane at once: each Stop blocks until its session closes.
        let lanes = bondLanes.compactMap(\.rt)
        bondLanes = []
        laneSilence = LaneSilenceWatch()
        if !lanes.isEmpty {
            DispatchQueue.concurrentPerform(iterations: lanes.count) { try? lanes[$0].stop(Self.stopTimeoutMs) }
        }
        try? runtime?.stop(Self.stopTimeoutMs)
        runtime = nil
        xraySession?.stop()
        xraySession = nil
    }

    private func failLiveness() {
        // Invalidate FIRST: cancelling an outstanding probe completes it
        // synchronously and must not re-enter failure handling.
        stopLivenessWatch()
        cancelTunnelWithError(NEVPNError(.connectionFailed))
        teardownLocked() // #484: release the runtime even if the OS does not call stop again.
    }
    // eoc #484

    private func teardownLocked() {
        // #484: late callbacks from a stopped generation cannot cancel its successor.
        livenessGeneration = UUID()
        livenessProbe?.cancel()
        livenessProbe = nil
        livenessTimer?.cancel()          // #469
        livenessTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pendingRejoin?.cancel()
        pendingRejoin = nil
        pendingLoss?.cancel()
        pendingLoss = nil
        recovery = VPNSessionRecovery()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        try? tunnel?.close()
        tunnel = nil
        stopCoreLocked()
        startedAt = nil
        widgetReporter.tunnelDown()
        // #470: this stop is done with; a later start on this instance must
        // not read it as "arrived early".
        startLock.lock()
        stopArrivedEarly = false
        waitingRuntime = nil
        startLock.unlock()
    }

    // MARK: App messages ("stats" / "logs" from VPNController)
    //
    // "stats" is polled ~1/s by the app while it is connected and the main
    // screen is visible (TunnelThroughputMonitor); it must stay cheap.

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let message = String(data: messageData, encoding: .utf8) ?? ""
        workQueue.async {
            switch message {
            case "stats":
                completionHandler(self.statsJSON())
            case "logs":
                let text = self.logBuffer.tail().joined(separator: "\n")
                completionHandler(Data(text.utf8))
            default:
                completionHandler(nil)
            }
        }
    }

    /// The "stats" message format version. Mirrors
    /// `VPNController.ProviderStats.version`; bump both on incompatible change.
    static let statsVersion = 1

    /// Runs on workQueue. JSON keys are decoded by `VPNController.ProviderStats`
    /// (app side); `TunnelThroughputMonitor` turns rx/tx deltas into the main
    /// screen's throughput readout, so the counters must stay cumulative.
    private func statsJSON() -> Data? {
        var stats: [String: Any] = [
            "v":            Self.statsVersion,
            "state":        coreStatus()?.state ?? "idle",
            "running":      coreStatus()?.running ?? false,
            "tunnelActive": tunnel != nil,
            "monotonicMs":  Int64(ProcessInfo.processInfo.systemUptime * 1000),
        ]
        if let tunnel {
            stats["rxBytes"] = tunnel.rxBytes()   // toward the device
            stats["txBytes"] = tunnel.txBytes()   // from the device
        }
        if let startedAt {
            stats["uptimeSeconds"] = Int(Date().timeIntervalSince(startedAt))
        }
        if let client = bondClient {
            stats["laneBytes"] = client.laneBytes()   // "rx:tx" per lane, OlcrtcEngine.parseLaneBytes
        }
        if let x = xraySession {
            stats["engine"] = VPNConfig.engineXray
            if let reason = x.lastHealthReason { stats["health"] = reason }
        }
        return try? JSONSerialization.data(withJSONObject: stats)
    }
}

// MARK: - FlowWriter (lwIP -> OS)
//
// Go-side TunWriter: tunstack's read pump calls writePacket from a Go
// goroutine for every outbound IP packet. gomobile only guarantees the Data
// view of a Go []byte for the duration of the call, so copy before handing it
// to writePackets (which retains).
private final class FlowWriter: NSObject, TunstackTunWriterProtocol {
    private let flow: NEPacketTunnelFlow
    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    func writePacket(_ p: Data?) {
        guard let p, !p.isEmpty else { return }
        flow.writePackets([Data(p)], withProtocols: [NSNumber(value: AF_INET)])
    }
}

// MARK: - ExtensionLogCapture
//
// Same bridge as TunnelEngine's LogCapture, but for the extension process
// (each process statically links its own Go runtime, so MobileSetLogWriter
// here only affects this process). Feeds the ring buffer, not LogStore.
private final class ExtensionLogCapture: NSObject, MobileLogWriterProtocol {
    var onLog: ((String) -> Void)?
    func writeLog(_ msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(msg)
    }
}

// MARK: - LogRingBuffer
//
// Fixed-capacity, thread-safe line buffer: the Go log writer appends from
// arbitrary goroutine threads, handleAppMessage reads on workQueue.
final class LogRingBuffer {
    private let capacity: Int
    private var lines: [String] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func tail(_ maxLines: Int = Int.max) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(maxLines))
    }
}
