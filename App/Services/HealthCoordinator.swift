import Foundation
import SwiftUI

// MARK: - HealthCoordinator (#456)
//
// #456: the ONE owner of verified-health evidence. Nothing else in the app is
// allowed to run a health probe, and nothing else writes `NodeHealth`.
//
// WHY A SINGLETON (a deliberate deviation from AGENTS.md's "app-wide stores are
// @StateObject on MainTabView, passed by initializer"):
//   • it is read by views on TWO tabs (Manage VPS + Connections) AND written by
//     NON-view code (`TunnelManager`, from `runEngine` and the keep-alive loop),
//     so there is no single view that could own it;
//   • threading it through four initializers would couple every screen to one
//     memberwise-init argument order — the exact class of bug that has broken
//     CI in this repo before.
// It follows the existing precedent of `SettingsStore.shared` and
// `LogStore.shared`: views observe it with
// `@ObservedObject private var health = HealthCoordinator.shared`.
//
// PROBE DISCIPLINE (all of it deliberate, none of it decoration):
//   • A FEW AT A TIME — at most `maxParallelProbes` olcrtc probes together.
//     Each is a client of its own in Go (`Runtime.Ping` builds an isolated
//     config, the way the lanes of a bonded session run side by side). A WB
//     Stream probe runs alone: its account token is pinned on the shared
//     runtime defaults. Xray probes go one at a time through the one olcos core.
//   • DEBOUNCED — `shouldProbe` refuses a re-probe inside `minRecheckSeconds`
//     unless the user forced it.
//   • STALENESS-DRIVEN — an automatic sweep only touches `.never`/`.stale`
//     nodes and is capped at `autoSweepMaxNodes`.
//   • NEVER the live room — reuses `TunnelManager.shouldSkipBatchPing` verbatim,
//     re-read on each probe (two peers sharing one identity in a carrier room
//     break each other).
//   • REFUSES to run under a live system VPN — a probe's carrier signalling
//     would ride the very tunnel it is trying to measure while its ICE
//     candidates deliberately exclude utun, so every node would read dead. That
//     is `.inconclusive(.vpnActive)`, an honest "couldn't check".
//   • OWN 20 s BUDGET — never the user's 60 s start timeout, so a hung carrier
//     costs 20 s, not a minute per node.
//
// Nothing here runs at app launch and nothing runs automatically on the
// Connections tab: each probe is a real conference join on a third-party
// service costing ~5–15 s, cellular data and CPU. Persistence + a visible age
// answer "what worked recently" at launch for free.

@MainActor
final class HealthCoordinator: ObservableObject {

    static let shared = HealthCoordinator()

    /// Bumped on every store/in-flight change. Views observe `$revision`; the map
    /// itself is deliberately NOT @Published (same rule as LogStore.entries).
    @Published private(set) var revision: Int = 0

    // MARK: Persistence
    //
    // UserDefaults key: "olcrtc_health_v1" — BRAND NEW. Value: JSON
    // [String: NodeHealth] keyed by ConnectionRecord.id.uuidString. A decode
    // failure yields an EMPTY map and touches no other key, so it can never harm
    // `olcrtc_records_v2` (whose decode failure wipes the user's connections).
    private static let storeKey = "olcrtc_health_v1"
    private static let writeQueue = DispatchQueue(label: "olcrtc.health.userdefaults")

    private var store: [String: NodeHealth] = [:]
    /// Last known non-secret state per server host (App/Models/NodeHealth.swift,
    /// `HostSnapshot`), keyed by ServerHost.id.uuidString. Separate key so a
    /// decode failure here cannot touch the health map, and vice versa.
    private static let hostSnapshotKey = "olcrtc_host_snapshot_v1"
    private var hostSnapshots: [String: HostSnapshot] = [:]
    private var inFlight: Set<UUID> = []
    /// Probes waiting for a slot or running, per record: what `cancelAll`
    /// cancels (a queued one gives up; a native probe already dialling finishes).
    private var probeTasks: [UUID: Task<Void, Never>] = [:]
    /// How many probes run at once. Each olcrtc probe is a client of its own in
    /// Go (`Runtime.Ping` snapshots the shared defaults and builds its own
    /// config), so several share a moment and an opening sweep takes about one
    /// probe's time instead of one per protocol. Two things stay single: a WB
    /// Stream probe (its account token lives in those shared defaults) and the
    /// Xray probes (one olcos core answers them).
    static let maxParallelProbes = 4
    private enum ProbeLane { case olcrtc, xray }
    /// What one probe takes: its engine, whether it needs it alone, and the
    /// rooms it joins — two probes never sit in one room at once (a whole-
    /// server record and a protocol's own share rooms), as a second client in
    /// a room costs the first its session on some services.
    private struct ProbeSlot {
        let lane: ProbeLane
        let alone: Bool
        let rooms: Set<OlcrtcLane>
    }
    private var runningProbes: [ProbeLane: Int] = [:]
    private var exclusiveLanes: Set<ProbeLane> = []
    private var busyRooms: [OlcrtcLane: Int] = [:]
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The current automatic/`verifyAll` sweep — cancelled by the next sweep and
    /// by `cancelAll()`.
    private var sweepTask: Task<Void, Never>?
    /// #470: is the running sweep the one the USER asked for ("Check all",
    /// pull-to-refresh)? Every foreground transition and tab entry calls
    /// `verifyDue`, which cancelled whatever was running — so a forced sweep was
    /// routinely killed a few rows in and the user's own request never finished.
    /// An automatic pass now yields to a forced one; a forced pass supersedes
    /// anything.
    private var sweepForced = false
    // #482: only the current generation may clear sweep state on completion.
    private var sweepGeneration = UUID()
    var forcedSweepRunning: Bool {
        sweepForced && sweepTask != nil && !(sweepTask?.isCancelled ?? true)
    }

    /// #456 (audit fix): the ageing clock. `HealthDisplay` is derived from
    /// `Date()` at render time, but the only redraw trigger is `$revision`, which
    /// bumps on WRITES — so a verdict rendered green sat there green until some
    /// unrelated probe happened to write. Freshness that never expires on screen
    /// is the same lie as an undated claim. This wakes while anything is stored,
    /// so `.verified` visibly demotes to "worked" and then to stale on its own.
    /// It wakes once a minute and publishes only when a verdict has actually
    /// crossed a boundary (`agePhases`): a tick that changes nothing must not
    /// redraw every screen that shows a verdict. It stops itself when the store
    /// empties.
    private var ageTicker: Task<Void, Never>?
    private static let ageTickSeconds: UInt64 = 60
    /// Which side of `freshSeconds` / `staleSeconds` each stored verdict was on
    /// when views were last told to redraw.
    private var lastAgePhases: [String: Int] = [:]

    // #482 was: private init() always loaded global persistence.
    // In-memory instances allow deterministic scheduling tests without native IO.
    init(loadPersisted: Bool = true) {
        if loadPersisted {
            load()
            loadHostSnapshots()
            startAgeTickerIfNeeded()
        }
    }

    // MARK: Host snapshots

    /// The last known state of a host, or nil when it was never probed.
    func hostSnapshot(for hostID: UUID) -> HostSnapshot? {
        hostSnapshots[hostID.uuidString]
    }

    /// Record a probe result for a host. Persisted asynchronously; bumps
    /// `revision` so cards redraw.
    func noteHostSnapshot(_ snapshot: HostSnapshot, for hostID: UUID) {
        let previous = hostSnapshots[hostID.uuidString]
        hostSnapshots[hostID.uuidString] = snapshot
        saveHostSnapshots()
        // Views read only the base state from a snapshot (the rest seeds a view
        // once); a re-read that found the same base changes nothing on screen.
        if previous?.base != snapshot.base { bump() }
    }

    /// Drop a host's snapshot (host removed / server uninstalled).
    func forgetHost(_ hostID: UUID) {
        guard hostSnapshots.removeValue(forKey: hostID.uuidString) != nil else { return }
        saveHostSnapshots()
        bump()
    }

    /// Tab-entry throttle for one host: false while its last probe is younger
    /// than `HostSnapshotPolicy.recheckSeconds`, unless forced.
    func shouldRecheckHost(_ hostID: UUID, force: Bool, now: Date = Date()) -> Bool {
        HostSnapshotPolicy.shouldRecheck(lastProbedAt: hostSnapshot(for: hostID)?.probedAt,
                                         force: force, now: now)
    }

    private func loadHostSnapshots() {
        hostSnapshots = Self.decodeHostSnapshots(
            UserDefaults.standard.data(forKey: Self.hostSnapshotKey), now: Date())
    }

    /// Pure decode + forget-window filter; corrupt data ⇒ empty map, never throws.
    nonisolated static func decodeHostSnapshots(_ data: Data?, now: Date) -> [String: HostSnapshot] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: HostSnapshot].self, from: data)
        else { return [:] }
        let cutoff = now.addingTimeInterval(-HostSnapshotPolicy.forgetSeconds)
        return decoded.filter { $0.value.probedAt > cutoff }
    }

    private func saveHostSnapshots() {
        guard let data = try? JSONEncoder().encode(hostSnapshots) else { return }
        let key = Self.hostSnapshotKey
        Self.writeQueue.async { UserDefaults.standard.set(data, forKey: key) }
    }

    private func bump() {
        revision &+= 1
        lastAgePhases = Self.agePhases(of: store, now: Date())
    }

    // boc #474: automatic checking used to fire on EVERY tab appearance, so
    // walking between screens re-swept everything, over and over, while the
    // user did nothing. Automatic means once: the app comes to the foreground,
    // the first screen that wants a pass takes it, and nothing else runs by
    // itself until the app is backgrounded and returns. Pulling down is never
    // affected — a pull is the user asking, and it always checks.
    private var autoPassTaken = false
    private var serverPassTaken = false

    /// #482: call only on an actual background return, not inactive → active.
    /// The app came to the foreground: automatic passes are allowed again.
    func noteForegrounded() {
        autoPassTaken = false
        serverPassTaken = false
    }

    /// Claims this foreground session's automatic health sweep. Both tabs sweep
    /// the same records, so whichever opens first does it and the other stands
    /// down. Returns false when it has already been taken.
    func claimAutomaticSweep() -> Bool {
        guard !autoPassTaken else { return false }
        autoPassTaken = true
        return true
    }

    /// The same, for the Servers tab's SSH readiness pass — separate because it
    /// measures something else (the machine, not the protocols) and costs an SSH
    /// connection per host.
    func claimServerPass() -> Bool {
        guard !serverPassTaken else { return false }
        serverPassTaken = true
        return true
    }
    // eoc #474

    /// #456: run the ageing clock exactly while there is something to age.
    private func startAgeTickerIfNeeded() {
        guard ageTicker == nil, !store.isEmpty else { return }
        lastAgePhases = Self.agePhases(of: store, now: Date())
        ageTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(Self.ageTickSeconds)))
                guard let self, !Task.isCancelled else { return }
                guard !self.store.isEmpty else {
                    self.ageTicker = nil
                    return
                }
                // Redraw only when a verdict has crossed a boundary since the
                // last redraw — the dated words themselves are clock times.
                if Self.agePhases(of: self.store, now: Date()) != self.lastAgePhases { self.bump() }
            }
        }
    }

    /// 0 = inside `freshSeconds`, 1 = past it, 2 = past `staleSeconds`. A
    /// verdict looks different only when its number changes.
    nonisolated static func agePhase(of health: NodeHealth, now: Date) -> Int {
        let age = max(0, now.timeIntervalSince(health.checkedAt))
        if age >= HealthPolicy.staleSeconds { return 2 }
        return age >= HealthPolicy.freshSeconds ? 1 : 0
    }

    nonisolated static func agePhases(of store: [String: NodeHealth], now: Date) -> [String: Int] {
        store.mapValues { agePhase(of: $0, now: now) }
    }

    // MARK: Reads

    func health(for recordID: UUID) -> NodeHealth? { store[recordID.uuidString] }

    func display(for recordID: UUID, now: Date = Date()) -> HealthDisplay {
        Self.display(for: store[recordID.uuidString],
                     checking: inFlight.contains(recordID),
                     now: now)
    }

    func isChecking(_ recordID: UUID) -> Bool { inFlight.contains(recordID) }

    /// What a row SHOWS. Unlike `display(for:)` it does not blank a measured
    /// verdict while a re-check runs: the last value stays on screen (the row
    /// asks `isChecking` for its small spinner) until the new one lands. Only a
    /// record with nothing measured yet reads `.checking`.
    ///
    /// The record the live tunnel runs through reads as carrying it
    /// (`HealthDisplay.carryingLiveTunnel`): every screen asks here, so none of
    /// them can show a failure or "not checked" for the connection that is
    /// carrying traffic.
    func settledDisplay(for recordID: UUID, now: Date = Date()) -> HealthDisplay {
        Self.settledDisplay(for: store[recordID.uuidString],
                            checking: inFlight.contains(recordID),
                            live: liveRecordID() == recordID, now: now)
    }

    nonisolated static func settledDisplay(for health: NodeHealth?, checking: Bool, live: Bool = false,
                                           now: Date) -> HealthDisplay {
        let shown = Self.display(for: health, checking: checking && health == nil, now: now)
        return live ? shown.carryingLiveTunnel() : shown
    }

    /// The record the live tunnel runs through right now; `TunnelManager` sets
    /// it, so the coordinator never holds a copy that can go stale.
    var liveRecordID: @MainActor () -> UUID? = { nil }

    /// The records whose protocol container is not running, as the servers'
    /// last listings found them; set by AppServices, which holds the stores.
    /// They are not checked automatically, and a whole-server connection does
    /// not stand on them.
    var stoppedRecords: @MainActor () -> Set<UUID> = { [] }

    /// `stoppedRecords` from the persisted listings of `hosts`. The record the
    /// live tunnel runs through is never stopped: its traffic says otherwise.
    func stoppedRecordIDs(hosts: [ServerHost], records: [ConnectionRecord]) -> Set<UUID> {
        var ids = Set<UUID>()
        for host in hosts {
            guard let carriers = hostSnapshot(for: host.id)?.carriers, !carriers.isEmpty else { continue }
            ids.formUnion(StoppedProtocols.recordIDs(host: host, rows: carriers.map(\.carrierInfo), records: records))
        }
        if let live = liveRecordID() { ids.remove(live) }
        return ids
    }

    // boc #472: a verdict describes ONE deployment — this protocol, in this room,
    // under this key. Change any of them and the verdict is no longer about this
    // record, but nothing dropped it: after "generate new key", after a manual
    // key edit, after a room change, the row kept showing the PREVIOUS failure
    // (usually "Key no longer matches") until the user pressed Verify by hand.
    // The server was fine; the app was quoting a measurement of something that
    // no longer existed. Forgetting is the honest move: the row falls back to
    // "not checked", which is true, and the next sweep re-measures it — with no
    // debounce to wait out, because `shouldProbe` has nothing to debounce
    // against once the entry is gone.
    func forget(recordID: UUID) {
        // #482: an old queued/running probe must not restore an invalid verdict.
        recordGenerations[recordID, default: 0] &+= 1
        guard store.removeValue(forKey: recordID.uuidString) != nil else { return }
        save(); bump()
    }

    /// What a verdict is about. Two records with the same fingerprint can be
    /// measured interchangeably; a different one needs its own measurement.
    /// The key is HASHED — `NodeHealth` is persisted to UserDefaults and a
    /// secret must never land there (AGENTS.md).
    nonisolated static func fingerprint(_ record: ConnectionRecord) -> String? {
        switch record.details {
        case .olcrtc(let p):
            return "\(p.carrier)|\(p.transport)|\(p.roomID)|\(p.clientID)|\(p.key.hashValue)"
        case .xray(let p):
            // Same rule: everything that defines the endpoint, the secret hashed.
            return "xray|\(p.host)|\(p.port)|\(p.sni)|\(p.publicKey)|\(p.shortID)|\(p.uuid.hashValue)"
        }
    }
    // eoc #472

    // #482: configuration ownership survives forget even before a first verdict.
    private var recordGenerations: [UUID: UInt64] = [:]

    /// The node `BestChoice` picks among `recordIDs`, judged on the STORED
    /// verdicts: a node being re-checked keeps its last result here, so the
    /// mark does not hop to a slower node for the length of a probe.
    func bestChoice(among recordIDs: [UUID], now: Date = Date()) -> UUID? {
        BestChoice.pick(recordIDs.map { id in
            (id: id, display: Self.display(for: store[id.uuidString], checking: false, now: now))
        })
    }

    /// Aggregated verdict for a set of nodes — the Manage VPS card headline.
    /// Built from the SETTLED verdicts, so the headline does not flip to
    /// "Checking…" every time one protocol of the card is re-measured.
    func summary(for recordIDs: [UUID], now: Date = Date()) -> HealthDisplay {
        Self.summarize(recordIDs.map { settledDisplay(for: $0, now: now) })
    }

    /// The protocols a whole-server connection joins, each with its settled
    /// verdict — what the whole-server row stands on and the rooms it names
    /// when they do not answer. `stopped` defaults to `stoppedRecords()`.
    func bundleMarks(for bundle: ConnectionRecord, among records: [ConnectionRecord],
                     stopped: Set<UUID>? = nil, now: Date = Date()) -> [ProtocolMark] {
        let stopped = stopped ?? stoppedRecords()
        return ServerBundle.rooms(of: bundle, in: records).compactMap { record in
            guard case .olcrtc(let p) = record.details else { return nil }
            return ProtocolMark(name: CarrierTransportMatrix.carrierLabel(p.carrier),
                                display: settledDisplay(for: record.id, now: now),
                                stopped: stopped.contains(record.id))
        }
    }

    /// What a whole-server connection shows: its own verdict while the live
    /// tunnel runs through it, else the best evidence of its own check and of
    /// the rooms it joins. Its own check reaches the first room only, so a room
    /// that answers is evidence for the whole. A stopped room is no evidence,
    /// and neither is its own old verdict once its first room is stopped.
    func bundleDisplay(for bundle: ConnectionRecord, among records: [ConnectionRecord],
                       stopped: Set<UUID>? = nil, now: Date = Date()) -> HealthDisplay {
        let stopped = stopped ?? stoppedRecords()
        let own = stopped.contains(bundle.id) ? HealthDisplay.never : settledDisplay(for: bundle.id, now: now)
        let rooms = bundleMarks(for: bundle, among: records, stopped: stopped, now: now).filter { !$0.stopped }
        return Self.bundleDisplay(own: own, rooms: rooms.map(\.display))
    }

    nonisolated static func bundleDisplay(own: HealthDisplay, rooms: [HealthDisplay]) -> HealthDisplay {
        if own.isVerified { return own }
        // A room being measured for the first time must not hide the evidence
        // of the others.
        let all = [own] + rooms
        let measured = all.filter { !$0.isChecking }
        return summarize(measured.isEmpty ? all : measured)
    }

    /// #456 (audit fix): how many of these nodes are KNOWN to be failing, and how
    /// many there are in total. `summary` deliberately reports the best evidence
    /// ("at least one protocol works" is the useful headline), but on its own that
    /// lets a host with one working and one dead protocol read as simply fine —
    /// a known failure hidden behind an average. The card pairs the headline with
    /// this count so a failure is never silent. `.inconclusive` is NOT counted:
    /// couldn't-check is not a failure verdict.
    func failingCount(for recordIDs: [UUID], now: Date = Date()) -> (failing: Int, total: Int) {
        let failing = recordIDs.reduce(into: 0) { acc, id in
            switch display(for: id, now: now) {
            case .broken, .handshakeOnly: acc += 1
            default: break
            }
        }
        return (failing, recordIDs.count)
    }

    // MARK: Writes (free evidence — no probe required)

    /// #456: the live tunnel just passed `verifyTunnel` (HTTP 200 through its own
    /// SOCKS port). That is the strongest possible proof and costs nothing.
    func noteLiveVerified(recordID: UUID, rttMs: Int?) {
        store[recordID.uuidString] = NodeHealth(kind: .working, rttMs: rttMs, source: "live")
        save(); bump()
    }

    /// #456: a raw failure string from the engine / a connect attempt. Mapped to a
    /// stable reason; "couldn't check" reasons are stored as `.inconclusive`, never
    /// as `.broken` (requirement 2).
    /// `classified` — a reason already determined at the THROW site, where the
    /// raw core text (always English) was still available. Prefer it: `raw` is
    /// frequently the app's own LOCALIZED sentence by the time it arrives here,
    /// and substring-matching English needles against Russian text resolved every
    /// real failure to `.unknown` — i.e. filed as "couldn't check" (#456).
    func noteFailure(recordID: UUID, raw: String, source: String,
                     classified: HealthReason? = nil) {
        let reason = classified ?? HealthFailureMapper.reason(forRaw: raw)
        let kind: NodeHealthKind = HealthFailureMapper.isInconclusive(reason) ? .inconclusive : .broken
        store[recordID.uuidString] = NodeHealth(kind: kind,
                                                reason: reason,
                                                detail: LogStore.redactSecrets(raw),
                                                source: source)
        save(); bump()
    }

    /// #456: we could NOT check (VPS unreachable, no network, system VPN on).
    /// Explicitly not a failure verdict about the node.
    func noteInconclusive(recordID: UUID, reason: HealthReason) {
        store[recordID.uuidString] = NodeHealth(kind: .inconclusive, reason: reason, source: "probe")
        save(); bump()
    }

    /// #456 (additive to the sketched three writers): the link came UP but no data
    /// passed — the user's exact telemost incident (container Up, sessions opening,
    /// `traffic: in=0 out=0`). `TunnelManager` reports it from the OLC-1009 verify
    /// failure and from keep-alive loss. Routing those through `noteFailure` would
    /// map their localized message to `.unknown` ⇒ grey "couldn't check", which is
    /// dishonest: we DID check, and the answer was "connects but no data" (amber).
    func noteHandshakeOnly(recordID: UUID, detail: String, source: String) {
        // No `reason`: `.handshakeOnly` renders no reason, and asserting one here
        // ("nobody answered") would be false — somebody DID answer.
        store[recordID.uuidString] = NodeHealth(kind: .handshake,
                                                detail: LogStore.redactSecrets(detail),
                                                source: source)
        save(); bump()
    }

    // MARK: Probing

    /// Verifies ONE node end to end. Returns the resulting display. `force` skips
    /// the debounce AND enables the `checkReady` fallback that distinguishes
    /// "joined the room but no data passed" from a hard failure.
    @discardableResult
    func verify(_ record: ConnectionRecord, using tunnel: TunnelManager, force: Bool) async -> HealthDisplay {
        let id = record.id
        guard !inFlight.contains(id) else { return .checking }
        let carrier: String? = {
            if case .olcrtc(let p) = record.details { return p.carrier }
            return nil
        }()
        guard Self.shouldProbe(existing: store[id.uuidString], force: force, now: Date(), carrier: carrier) else {
            return display(for: id)
        }
        inFlight.insert(id); bump()
        let generation = recordGenerations[id, default: 0] // #482
        let slot = Self.probeSlot(for: record)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.acquireProbeSlot(slot)
            defer { self.releaseProbeSlot(slot) }
            // boc #470: `cancelAll()` cancels a probe while it is QUEUED for a
            // slot. The `MobilePing` inside `runProbe` is a detached task and
            // inherits nothing, so the flag is honoured here, before the dial:
            // the row stops saying "Checking…" and keeps its old verdict.
            // #482 was: Task.isCancelled alone allowed a queued old config.
            if Task.isCancelled || self.recordGenerations[id, default: 0] != generation {
                self.inFlight.remove(id); self.bump()
                return
            }
            // eoc #470
            await self.runProbe(record, using: tunnel, deep: force, generation: generation) // #482
        }
        probeTasks[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if probeTasks[id] == task { probeTasks[id] = nil }
        return display(for: id)
    }

    /// Which engine answers this record's probe, whether it must run alone,
    /// and the rooms it joins.
    private static func probeSlot(for record: ConnectionRecord) -> ProbeSlot {
        switch record.details {
        case .olcrtc(let p): return ProbeSlot(lane: .olcrtc, alone: p.carrier == "wbstream", rooms: Set(p.lanes))
        default:             return ProbeSlot(lane: .xray, alone: false, rooms: [])
        }
    }

    private func mayStartProbe(_ slot: ProbeSlot) -> Bool {
        guard !exclusiveLanes.contains(slot.lane) else { return false }
        guard slot.rooms.allSatisfy({ busyRooms[$0, default: 0] == 0 }) else { return false }
        let running = runningProbes[slot.lane, default: 0]
        if slot.alone { return running == 0 }
        return running < (slot.lane == .xray ? 1 : Self.maxParallelProbes)
    }

    private func acquireProbeSlot(_ slot: ProbeSlot) async {
        while !mayStartProbe(slot) {
            await withCheckedContinuation { probeWaiters.append($0) }
        }
        runningProbes[slot.lane, default: 0] += 1
        if slot.alone { exclusiveLanes.insert(slot.lane) }
        for room in slot.rooms { busyRooms[room, default: 0] += 1 }
    }

    private func releaseProbeSlot(_ slot: ProbeSlot) {
        runningProbes[slot.lane] = max(0, runningProbes[slot.lane, default: 0] - 1)
        if slot.alone { exclusiveLanes.remove(slot.lane) }
        for room in slot.rooms {
            let left = busyRooms[room, default: 0] - 1
            busyRooms[room] = left > 0 ? left : nil
        }
        let waiting = probeWaiters
        probeWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// A sweep's probes, all started together; the slots in `verify` decide how
    /// many of them really run at once.
    private func verifyTogether(_ batch: [ConnectionRecord], generations: [UUID: UInt64],
                                using tunnel: TunnelManager, force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for r in batch {
                if Task.isCancelled { break }
                guard recordGenerations[r.id, default: 0] == generations[r.id, default: 0] else { continue } // #482
                group.addTask { @MainActor in
                    await self.verify(r, using: tunnel, force: force)
                }
            }
        }
    }

    /// The actual probe. Ping (the only green) first; on failure, a forced check
    /// additionally runs `checkReady` so "handshake ok, data path dead" — the
    /// user's exact telemost case — is distinguishable from a hard failure.
    private func runProbe(_ record: ConnectionRecord, using tunnel: TunnelManager, deep: Bool,
                          generation: UInt64) async { // #482: retain the queued config owner.
        defer { inFlight.remove(record.id); bump() }

        // boc #482: a tab-entry sweep can beat App.swift's adoption task. Resolve
        // system state here too, before any native client can join a room.
        await tunnel.vpn.adoptRunningTunnel()
        guard !Task.isCancelled, recordGenerations[record.id, default: 0] == generation else { return }
        // #485: an up/down cycle can end in the same visible state while the
        // native probe is suspended. Endpoint state alone cannot prove its route.
        let routeRevision = tunnel.routeRevision
        // eoc #482

        // #456: REUSE the existing self-collision rule verbatim — never a second
        // rule. The live session is continuously verified by verifyTunnel /
        // keep-alive, which already writes `.working` for it.
        // #469: this check now runs FIRST. It used to sit below the VPN guard,
        // which WROTE `.inconclusive(.vpnActive)` for every record — including
        // the one the VPN session itself runs through — so every foreground
        // sweep overwrote the connected node's real verdict with "couldn't
        // check — turn the VPN off". The node holding the live tunnel is never
        // a candidate for a side-channel probe in either mode.
        if TunnelManager.shouldSkipBatchPing(record: record,
                                             connectedNode: tunnel.engagedRecord,
                                             state: tunnel.state) {
            // Never a second client in a live room; its own traffic answers instead.
            if tunnel.liveRoomCarriesTraffic(record) {
                noteLiveVerified(recordID: record.id, rttMs: nil)
                LogStore.shared.log(.connection,
                    "Health: \(record.displayName) carries the live session's traffic")
            } else {
                LogStore.shared.log(.connection,
                    "Health: skipped \(record.displayName) — the live session uses its room")
            }
            return
        }

        // #456: a probe under a live system VPN is a mixed-path measurement —
        // its signalling rides the tunnel it is measuring. Honest answer: we
        // could not check.
        // boc #472 was: `tunnel.state.isConnected`. The system installs the VPN
        // routes when the provider answers `startTunnel`, which is BEFORE the
        // app's own state machine reaches `.connected` — and again while it sits
        // in `.waitingForNetwork`. In that window the guard was off but the
        // whole device was already tunnelled, so a Telemost probe went out
        // through the tunnel, reached Yandex from the SERVER's address, and was
        // refused (403) — recorded as a hard "the service refused you" verdict
        // about a node that is perfectly fine. Reported from the field: connect
        // through jitsi, turn the VPN on, and the telemost row goes red.
        // In VPN mode the only states where the routes are provably NOT ours are
        // idle and failed.
        // #477 was: `tunnel.activeMode == .vpn` plus a switch over `tunnel.state`
        // — the app's own belief about what it is running. A tunnel the user
        // started from iOS Settings carries the device just the same while
        // `activeMode` still reads `.proxy`, and every probe went out through it
        // and measured a mixed path anyway. `systemTunnelIsUp` answers the
        // question actually being asked.
        if tunnel.systemTunnelIsUp {
            // #472: "I cannot check right now" must not erase "I verified
            // this two minutes ago" — a fresh measurement is better evidence
            // than the absence of one, and overwriting it made a working
            // node go grey the moment the VPN came up.
            if let seen = store[record.id.uuidString],
               Date().timeIntervalSince(seen.checkedAt) < HealthPolicy.freshSeconds {
                LogStore.shared.log(.connection,
                    "Health: kept the fresh verdict for \(record.displayName) — the system VPN is up, so no new measurement is possible")
                return
            }
            noteInconclusive(recordID: record.id, reason: .vpnActive)
            LogStore.shared.log(.connection,
                "Health: skipped \(record.displayName) — can't probe while the system VPN is up")
            return
        }
        // eoc #472 / #477

        let probe = TunnelManager.recordForBatchPing(
            record, clientID: TunnelManager.batchPingClientID(recordID: record.id))
        // #456 (audit fix): remember how long we actually waited. A probe gets a
        // 20 s budget while a real connect gets the user's start timeout (60 s by
        // default), so a slow-but-alive carrier can fail HERE and succeed THERE.
        // Blaming the node for our own shorter deadline is a false negative — the
        // honest verdict for "we ran out of our own time" is "couldn't check".
        let probeStarted = Date()
        let budgetMs = HealthPolicy.probeTimeoutMs(for: record)
        let rtt = await tunnel.ping(probe.details, timeoutMs: budgetMs)
        // boc #482: edits/renewal or a route change while suspended invalidate
        // the result. In particular, never run the deeper join over a new VPN.
        guard !Task.isCancelled, recordGenerations[record.id, default: 0] == generation,
              tunnel.routeRevision == routeRevision, // #485: no mixed-session evidence
              !tunnel.systemTunnelIsUp,
              !TunnelManager.shouldSkipBatchPing(record: record,
                  connectedNode: tunnel.engagedRecord, state: tunnel.state) else { return }
        // eoc #482
        let hitOurCap = Date().timeIntervalSince(probeStarted)
            >= Double(budgetMs) / 1000 * 0.95

        switch rtt {
        case .success(let ms):
            store[record.id.uuidString] = NodeHealth(kind: .working, rttMs: ms, source: "probe")
            save(); bump()
            LogStore.shared.log(.connection,
                "Health: \(record.displayName) verified end to end — \(ms) ms")
        case .failure(let raw):
            // #470: a sentence the probe LAYER produced is classified here, in
            // whatever language it came, before the English-needle mapper sees it.
            let classified = Self.probeSideReason(forRaw: raw)
            if deep {
                let ready = await tunnel.checkReady(probe.details, timeoutMs: budgetMs)
                // #482: a deep probe may also outlive the configuration it measures.
                guard !Task.isCancelled, recordGenerations[record.id, default: 0] == generation,
                      tunnel.routeRevision == routeRevision, // #485: deep check has the same owner
                      !tunnel.systemTunnelIsUp,
                      !TunnelManager.shouldSkipBatchPing(record: record,
                          connectedNode: tunnel.engagedRecord, state: tunnel.state) else { return }
                if case .success = ready {
                    store[record.id.uuidString] = NodeHealth(
                        kind: .handshake,
                        reason: classified ?? HealthFailureMapper.reason(forRaw: raw),   // #470
                        detail: LogStore.redactSecrets(raw),
                        source: "probe")
                    save(); bump()
                    LogStore.shared.log(.connection,
                        "Health: \(record.displayName) joined the room but no data passed")
                    return
                }
            }
            // #456 (audit fix): our own deadline expiring is not evidence the
            // node is broken.
            // #469: …unless the core SAID why. Its ready-wait is bounded by the
            // very timeout we pass, so a stopped server or a dead room ALWAYS
            // came back at our cap — and was filed as grey "couldn't check"
            // (retry) instead of red "nobody answered" (recover). `.noPeer` was
            // unreachable from a probe. A raw error the mapper recognises is a
            // verdict; only an unclassified timeout is our deadline talking.
            let mapped = classified ?? HealthFailureMapper.reason(forRaw: raw)   // #470
            if hitOurCap, mapped == .timedOut || mapped == .unknown {
                noteInconclusive(recordID: record.id, reason: .timedOut)
                // #470: `level: .info` — the keyword classifier saw "failure" in
                // a sentence whose whole point is that this is NOT one, and
                // painted it red.
                LogStore.shared.log(.connection,
                    "Health: \(record.displayName) — no answer within the \(budgetMs / 1000)s check budget; not treating that as a failure",
                    level: .info)
                return
            }
            noteFailure(recordID: record.id, raw: raw, source: "probe", classified: classified)   // #470
            LogStore.shared.log(.connection,
                "Health: \(record.displayName) failed — \(LogStore.redactSecrets(raw))")
        }
    }

    /// #456: the automatic pass (entering Manage VPS). Only touches nodes whose
    /// verdict is `.never` or `.stale`, capped at `limit`, and returns IMMEDIATELY
    /// — it must never block the UI.
    func verifyStale(_ records: [ConnectionRecord], using tunnel: TunnelManager,
                     limit: Int = HealthPolicy.autoSweepMaxNodes) {
        let now = Date()
        let due: [ConnectionRecord] = records.filter { r in
            guard !inFlight.contains(r.id) else { return false }
            switch display(for: r.id, now: now) {
            case .never, .stale: return true
            default:             return false
            }
        }
        let batch = Array(due.prefix(limit))
        guard !batch.isEmpty else { return }
        let generations = recordGenerations // #482: snapshots queued in a sweep may age before verify().
        // #482 was: each entry point replaced the task and a shared Bool itself.
        startSweep(force: false) {
            await self.verifyTogether(batch, generations: generations, using: tunnel, force: false)
        }
    }

    /// #458: the on-entry pass. Unlike `verifyStale` it is not restricted to
    /// never/stale nodes and is NOT capped, so opening the app really does tell
    /// you about everything you own; unlike `verifyAll` it is not forced, so
    /// `shouldProbe`'s debounce still refuses to re-probe anything checked within
    /// `HealthPolicy.minRecheckSeconds`. Returns immediately — the coordinator
    /// runs the probes a few at a time and skips the room the live tunnel holds.
    func verifyDue(_ records: [ConnectionRecord], using tunnel: TunnelManager) {
        let batch = records.filter { !inFlight.contains($0.id) }
        guard !batch.isEmpty else { return }
        let generations = recordGenerations // #482: keep the snapshot's ownership.
        // #482: central ownership protects the current forced sweep.
        startSweep(force: false) {
            await self.verifyTogether(batch, generations: generations, using: tunnel, force: false)
        }
    }

    /// How many direct (Xray) servers an automatic sweep checks beyond the
    /// ones it always keeps.
    static let automaticDirectLimit = 8

    /// What an automatic sweep (the app opening) checks: every call protocol,
    /// every connection in `keep` (the one in use, the user's own servers'),
    /// and of the remaining direct servers only those that worked last time,
    /// at most `automaticDirectLimit`. A list of free servers holds dozens, and
    /// a full check of each on every opening would run for many minutes; the
    /// rest are checked by a pull or by the search for the fastest.
    ///
    /// `covered`: one protocol's records of a server whose whole-server
    /// connection holds their rooms (ServerBundle.coveredIDs). The whole-server
    /// record speaks for them on opening; each of their checks would join a
    /// room of that server once more. Their own page checks them.
    ///
    /// `stopped` (default `stoppedRecords()`): records whose container is not
    /// running are not checked. A stopped whole-server record speaks for no
    /// room, so the rooms it covered are checked on their own.
    func automaticSweepCandidates(_ records: [ConnectionRecord], keep: Set<UUID>,
                                  covered: Set<UUID> = [],
                                  stopped: Set<UUID>? = nil,
                                  now: Date = Date()) -> [ConnectionRecord] {
        let stopped = stopped ?? stoppedRecords()
        var covered = covered
        for bundle in records where bundle.isBundle && stopped.contains(bundle.id) {
            covered.subtract(ServerBundle.rooms(of: bundle, in: records).map(\.id))
        }
        var directLeft = Self.automaticDirectLimit
        return records.filter { record in
            guard !covered.contains(record.id), !stopped.contains(record.id) else { return false }
            guard case .xray = record.details, !keep.contains(record.id) else { return true }
            switch display(for: record.id, now: now) {
            case .verified, .fading:
                guard directLeft > 0 else { return false }
                directLeft -= 1
                return true
            default:
                return false
            }
        }
    }

    /// #456: the user asked for everything ("Check all"). No staleness filter, no
    /// limit, and forced — the debounce is a cost guard for AUTOMATIC passes only.
    func verifyAll(_ records: [ConnectionRecord], using tunnel: TunnelManager) {
        let batch = records.filter { !inFlight.contains($0.id) }
        guard !batch.isEmpty else { return }
        let generations = recordGenerations // #482: old configurations cannot regain a verdict.
        // #482 was: defer { self.sweepForced = false } in every forced task.
        startSweep(force: true) {
            await self.verifyTogether(batch, generations: generations, using: tunnel, force: true)
        }
    }

    // boc #482: a cancelled task can remain suspended behind a native probe.
    // Its defer must never clear the owner that replaced it. The work seam is
    // also used by no-network continuation tests of the actual scheduler.
    @discardableResult
    func startSweep(force: Bool, work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard force || !forcedSweepRunning else { return nil }
        sweepTask?.cancel()
        let generation = UUID()
        sweepGeneration = generation
        sweepForced = force
        sweepTask = Task { @MainActor in
            defer {
                if self.sweepGeneration == generation {
                    self.sweepForced = false
                    self.sweepTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            await work()
        }
        return sweepTask
    }
    // eoc #482

    /// #456: stop probing (view disappeared, tab switched away).
    ///
    /// An in-flight NATIVE probe cannot be interrupted — `MobilePing` blocks in Go
    /// until its own timeout. Cancellation therefore only stops the SWEEP; the
    /// in-flight probe runs to completion, keeps its `inFlight` slot (the row goes
    /// on saying "Checking…", which is true) and still writes its verdict.
    ///
    // boc #456 (audit): `tail = nil` + `inFlight.removeAll()` used to be here.
    // Both are bookkeeping for a probe that is STILL RUNNING in Go, and dropping
    // them let the very next `verify` start a SECOND native probe concurrently:
    //   • `TunnelManager.batchPingClientID` is DETERMINISTIC per record
    //     ("olc-ping-" + the record uuid's first 8 chars), so re-verifying the
    //     same node put two peers with ONE device id in one carrier room — the
    //     identity collision that breaks both of them;
    //   • it also raced the Go shared-runtime state (provider-token pinning on
    //     the shared defaults), which is why a WB Stream probe runs alone.
    // Reproducer: tap a row's chip → switch tabs (`.onDisappear` → cancelAll)
    // → switch back → tap the same chip.
    // #456 was: sweepTask?.cancel(); sweepTask = nil
    //           tail?.cancel(); tail = nil
    //           inFlight.removeAll()
    func cancelAll() {
        sweepTask?.cancel(); sweepTask = nil
        sweepGeneration = UUID() // #482: invalidate any suspended cleanup.
        sweepForced = false   // #470
        // #470: a probe checks `Task.isCancelled` once it has a slot, so this
        // really does stop a QUEUED one; a dialling one keeps its slot.
        for task in probeTasks.values { task.cancel() }
        bump()
    }
    // eoc #456 (audit)

    /// #470: the two sentences the PROBE LAYER itself can return (never the
    /// core): `OlcrtcEngine.ping` answers `pingNoFreePort` when the EPHEMERAL
    /// port pool is exhausted and `pingFailed` for a negative RTT. Both are
    /// localized, and `HealthFailureMapper` matches English needles — so an
    /// English UI filed the first as `.portBusy` ("open port settings", about
    /// the configured SOCKS port, which a probe never uses) while a Russian UI
    /// filed the same fault as `.unknown`. One verdict whatever the language:
    /// the app could not run its check — `.unknown`, i.e. inconclusive, retry.
    /// Compared at call time, never cached (the L10n rule); a Go-core line
    /// returns nil and goes to the mapper as before.
    nonisolated static func probeSideReason(forRaw raw: String) -> HealthReason? {
        if raw == L10n.pingNoFreePort.localized() || raw == L10n.pingFailed.localized() {
            return .unknown
        }
        return nil
    }

    /// #456: test hook. Deliberately NOT `#if DEBUG`-gated — the test bundle is
    /// built in the same configuration as the app here (TEST_HOST), and gating it
    /// would make the suite fail to compile in Release. Clears the in-memory map,
    /// the in-flight set and the persisted key.
    func _resetForTesting() {
        cancelAll()
        probeTasks.removeAll()     // #456 (audit): cancelAll no longer drops these
        inFlight.removeAll()       // — a test starts from a clean slate regardless
        runningProbes.removeAll()
        exclusiveLanes.removeAll()
        busyRooms.removeAll()
        let waiting = probeWaiters
        probeWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        store.removeAll()
        hostSnapshots.removeAll()
        save()
        saveHostSnapshots()
        bump()
    }

    // MARK: Persistence internals

    private func load() {
        store = Self.decodeStore(UserDefaults.standard.data(forKey: Self.storeKey), now: Date())
    }

    /// #456: pure decode + forget-window filter, factored out of `load()` so the
    /// "corrupt data ⇒ empty map, never throws" rule is directly unit-testable.
    nonisolated static func decodeStore(_ data: Data?, now: Date) -> [String: NodeHealth] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: NodeHealth].self, from: data)
        else { return [:] }                              // corrupt ⇒ start empty, never throw
        let cutoff = now.addingTimeInterval(-HealthPolicy.forgetSeconds)
        return decoded.filter { $0.value.checkedAt > cutoff }
    }

    private func save() {
        // #456 (audit fix): the store just became non-empty on a fresh install /
        // after a reset — start the ageing clock so the first verdict can expire
        // on screen without waiting for a second write.
        startAgeTickerIfNeeded()
        var out = store
        if out.count > HealthPolicy.maxEntries {
            let keep = out.sorted { $0.value.checkedAt > $1.value.checkedAt }
                          .prefix(HealthPolicy.maxEntries)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(out) else { return }
        let key = Self.storeKey
        Self.writeQueue.async { UserDefaults.standard.set(data, forKey: key) }
    }

    /// #456: test hook — drains the async UserDefaults write, mirroring
    /// `SettingsStore.flushPendingWrites()`.
    static func flushPendingWrites() {
        writeQueue.sync { }
    }

    // MARK: Pure rules (unit-tested in Tests/HealthModelTests.swift)

    /// The staleness rule. Pure → tested. `checking` wins over everything so a
    /// re-check never briefly shows an old verdict as current.
    nonisolated static func display(for health: NodeHealth?, checking: Bool, now: Date) -> HealthDisplay {
        if checking { return .checking }
        guard let h = health else { return .never }
        let age = max(0, now.timeIntervalSince(h.checkedAt))
        if age >= HealthPolicy.staleSeconds { return .stale(age: age) }
        switch h.resolvedKind {
        case .working:
            return age < HealthPolicy.freshSeconds ? .verified(ms: h.rttMs, age: age)
                                                   : .fading(ms: h.rttMs, age: age)
        case .handshake:    return .handshakeOnly(age: age)
        case .broken:       return .broken(h.resolvedReason, age: age)
        case .inconclusive: return .inconclusive(h.resolvedReason, age: age)
        case .unknown:      return .stale(age: age)
        }
    }

    /// The debounce rule. Pure → tested. A forced (user-initiated) check ignores
    /// the debounce; an automatic sweep additionally only touches STALE nodes —
    /// see `verifyStale`, which filters on `.stale`/`.never` before calling this.
    ///
    /// A Jitsi room is re-probed automatically far less often: after a probe
    /// leaves, the bridge tears the conference down and the server spends about
    /// a minute rejoining — a connect landing in that minute fails.
    nonisolated static func shouldProbe(existing: NodeHealth?, force: Bool, now: Date,
                                        carrier: String? = nil) -> Bool {
        guard let e = existing else { return true }
        if force { return true }
        let gap = carrier == "jitsi" ? HealthPolicy.jitsiRecheckSeconds : HealthPolicy.minRecheckSeconds
        return now.timeIntervalSince(e.checkedAt) >= gap
    }

    /// Aggregate several nodes into ONE headline (the VPS card). Best evidence
    /// wins, but "we could not check" never masquerades as "broken".
    /// Precedence: checking > verified > fading > handshakeOnly > broken > inconclusive > stale > never.
    nonisolated static func summarize(_ displays: [HealthDisplay]) -> HealthDisplay {
        func rank(_ d: HealthDisplay) -> Int {
            switch d {
            case .checking: return 0
            case .verified: return 1
            case .fading: return 2
            case .handshakeOnly: return 3
            case .broken: return 4
            case .inconclusive: return 5
            case .stale: return 6
            case .never: return 7
            }
        }
        return displays.min { rank($0) < rank($1) } ?? .never
    }
}
