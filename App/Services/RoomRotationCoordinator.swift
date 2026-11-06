import Foundation
import SwiftUI

// MARK: - RoomRotationPolicy
//
// WHEN a room is replaced on a schedule, as pure functions — every branch is a
// unit test (Tests/RoomRotationTests.swift). The side-effecting half is
// RoomRotationCoordinator.
//
// What applies to a room is decided per protocol (RoomRotationRule). VK Calls,
// SaluteJazz, MTS Link and Jitsi rooms do not expire, so replacing one is
// something the user asks for on a schedule (every 6 hours to weekly), within a
// window of the day (RoomRotationWindow), and every one of them is Off until
// they do. Telemost is not handled here: its rooms die after
// 24 hours, and TelemostRenewalCoordinator renews them on that clock under its
// own Automatic rule. MTS Link offers no schedule until the app has learned how
// the service makes a meeting and holds the sign-in
// (MTSLinkRoomService.canCreateRooms).
enum RoomRotationPolicy {

    /// After a "sign in again" failure the connection is left alone this
    /// long — retrying a refused credential every 15 minutes is noise, not
    /// effort.
    static let signInRetryDelay: TimeInterval = 24 * 3600

    /// How often the silent account check may run. It fires on the foreground
    /// pass, so "once a day" means once per day of actually opening the app.
    static let accountCheckInterval: TimeInterval = 24 * 3600

    /// How far past its due time a room that the live tunnel is using may wait
    /// for a quiet moment before it is replaced regardless.
    static let busyGrace: TimeInterval = 6 * 3600

    /// No tunnel traffic for this long counts as "nobody is using it" — the
    /// Telemost renewal's own measure, so the two unattended features agree.
    static let idleGrace: TimeInterval = TelemostRenewalPolicy.idleGrace

    // MARK: What a rule covers

    /// PURE. Whether `record` can take part in auto-update at all: a protocol
    /// record of a service that has a rule, and not a whole-server connection
    /// (a bundle's rooms belong to the protocol records it was derived from,
    /// and those are what change).
    static func isEligible(_ record: ConnectionRecord) -> Bool {
        guard case .olcrtc(let params) = record.details else { return false }
        return RoomRotationRule.carriers.contains(params.carrier) && !params.isBundle
    }

    /// PURE. Whether this phone administers `record`: a saved server it may
    /// manage (not one it only watches as an invited member) produced it.
    static func isManaged(_ record: ConnectionRecord, hosts: [ServerHost]) -> Bool {
        hosts.contains { $0.canManage && $0.links(record.id) }
    }

    /// PURE. The hours between replacements that apply to `record` under
    /// `rule`, its protocol's rule — or nil when none do: the record must be
    /// eligible and not excepted, and its protocol must offer `rule` as a
    /// schedule. So Off, Telemost's Automatic (its own coordinator's), and an
    /// MTS Link schedule saved before the app learned the create request all
    /// come out nil.
    static func scheduledHours(for record: ConnectionRecord, rule: RoomRotationRule,
                               exceptions: Set<UUID>,
                               mtslinkCanCreate: Bool = MTSLinkRoomService.canCreateRooms) -> Int? {
        guard isEligible(record), !exceptions.contains(record.id),
              case .olcrtc(let params) = record.details,
              RoomRotationRule.allowed(for: params.carrier,
                                       mtslinkCanCreate: mtslinkCanCreate).contains(rule)
        else { return nil }
        return rule.intervalHours
    }

    /// PURE. The connections the Exceptions list offers: protocol records this
    /// phone administers whose protocol's rule is on, in saved order.
    static func exceptionCandidates(in records: [ConnectionRecord], hosts: [ServerHost],
                                    ruleIsOn: (String) -> Bool) -> [ConnectionRecord] {
        records.filter { record in
            guard isEligible(record), case .olcrtc(let params) = record.details else { return false }
            return ruleIsOn(params.carrier) && isManaged(record, hosts: hosts)
        }
    }

    // MARK: When

    /// How often a pass looks when no scheduled rule has a window.
    static let basePassInterval: TimeInterval = 15 * 60

    /// How often a pass looks while a scheduled rule has a window, so a window
    /// of one hour is never stepped over.
    static let windowedPassInterval: TimeInterval = 10 * 60

    /// A chosen hour counts a room due this much before its interval is up,
    /// so a daily change at that hour does not slip a day.
    static let hourWindowLead: TimeInterval = 3600

    enum Decision: Equatable {
        /// No age is known, or the room is younger than its interval.
        case notDue
        /// Due: replace it now.
        case rotate
        /// Due, but the live tunnel rides this room and is in use. Look again
        /// on a later pass.
        case postpone
        /// Due for `busyGrace` longer than it was willing to wait: replace it
        /// although the tunnel is in use.
        case force
        /// Due, but now is outside the rule's window: nothing changes until
        /// the next one, however overdue the room is.
        case waitForWindow
    }

    /// PURE. How old a room must be to be due: the interval, less
    /// `hourWindowLead` when the window is one chosen hour.
    static func dueAfter(intervalHours: Int, window: RoomRotationWindow) -> TimeInterval {
        let interval = TimeInterval(intervalHours) * 3600
        guard case .hour(_) = window else { return interval }
        return max(interval - hourWindowLead, 0)
    }

    /// PURE. Whether `now` falls inside `window` by `calendar`'s clock (the
    /// phone's local time in production).
    static func isInWindow(_ window: RoomRotationWindow, now: Date, calendar: Calendar) -> Bool {
        window.contains(hourOfDay: calendar.component(.hour, from: now))
    }

    /// PURE. What to do with a room created at `roomCreatedAt` on a schedule of
    /// `intervalHours`. A room with no creation time is never "older than"
    /// anything — the coordinator quietly stamps one the first time it sees
    /// such a record, which starts the clock instead of guessing an age nobody
    /// recorded.
    ///
    /// A due room waits for its `window`: outside it nothing is replaced, and
    /// that holds for the busy cap below too.
    ///
    /// `tunnelBusy` means the live tunnel rides this room and is being used.
    /// Replacing the room restarts its container, which drops that tunnel for
    /// a few seconds, so a due room waits for a quiet moment — but not
    /// forever: `busyGrace` past its due time it goes regardless, at the
    /// first moment inside its window.
    static func decide(roomCreatedAt: Date?, intervalHours: Int, now: Date,
                       tunnelBusy: Bool, window: RoomRotationWindow = .anyTime,
                       calendar: Calendar = .current) -> Decision {
        guard intervalHours > 0, let created = roomCreatedAt else { return .notDue }
        let due = created.addingTimeInterval(dueAfter(intervalHours: intervalHours, window: window))
        guard now >= due else { return .notDue }
        guard isInWindow(window, now: now, calendar: calendar) else { return .waitForWindow }
        guard tunnelBusy else { return .rotate }
        return now.timeIntervalSince(due) >= busyGrace ? .force : .postpone
    }

    /// PURE. The wait between passes: short while a protocol on a schedule
    /// has a window, the usual otherwise.
    static func passInterval(rules: [String: RoomRotationRule],
                             windows: [String: RoomRotationWindow]) -> TimeInterval {
        let windowed = rules.contains(where: { entry in
            entry.value.hasWindow && (windows[entry.key] ?? .anyTime) != .anyTime
        })
        return windowed ? windowedPassInterval : basePassInterval
    }

    /// PURE. Whether the live session holds `record`'s room: the record
    /// itself, or a whole-server connection that joined it.
    static func isRiding(live: ConnectionRecord?, record: ConnectionRecord,
                         params: OlcrtcConnection) -> Bool {
        guard let live else { return false }
        if live.id == record.id { return true }
        guard case .olcrtc(let liveParams) = live.details, liveParams.isBundle else { return false }
        return ServerBundle.rides(liveParams, carrier: params.carrier, roomID: params.roomID)
    }

    /// PURE. Whether the live tunnel is in use. Only a connected SOCKS5 session
    /// whose last traffic is older than `idleGrace` is idle. A VPN session's
    /// traffic lives in the extension, a session still connecting has none to
    /// measure, and a session with no measured traffic is no evidence of rest:
    /// all of those count as in use.
    static func isTunnelBusy(activityIsObservable: Bool, lastActivity: Date?, now: Date) -> Bool {
        guard activityIsObservable, let last = lastActivity else { return true }
        return now.timeIntervalSince(last) < idleGrace
    }

    /// PURE. Whether a "sign in again" verdict still silences the connection.
    static func isBlocked(blockedUntil: Date?, now: Date) -> Bool {
        guard let blockedUntil else { return false }
        return now < blockedUntil
    }
}

// MARK: - RoomRotationCoordinator
//
// The side-effecting half of scheduled room rotation, modelled on
// TelemostRenewalCoordinator and owned the same way (built by AppServices,
// held by MainTabView): rotation has to keep working while the user is
// anywhere in the app, and it holds its OWN Provisioner so an unattended
// rotation cannot race a screen-driven operation for one SSH lane.
//
// Nothing about DELIVERING a room is reinvented here. A rotated room is
// applied through `Provisioner.reconfigure` — the same SSH path a manual
// room change takes — confirmed against the URI the server prints back
// (`TelemostRenewalCoordinator.confirms`), and the record is corrected in
// place exactly the way a renewal corrects it. The room-creation date rides
// the same `roomCreatedAt` field the Telemost clock uses. Each protocol brings
// its own room creator; everything after the creation is shared.
//
// There is no local-notification framework in this app (and adopting one
// means a new permission nobody asked for), so outcomes surface the way the
// Telemost renewal's do: LogStore lines, plus the honest state of the
// Accounts screen — a session the daily check has watched the service refuse
// is unlinked, so "signed in" stops being a claim the app cannot back.
@MainActor
final class RoomRotationCoordinator: ObservableObject {

    /// Where a rotated room is delivered — the same resolution the Telemost
    /// renewal makes (linked host, usable secret, prepared trust, container).
    struct Target: Equatable {
        let host: ServerHost
        let secret: SSHSecret
        let container: String
    }

    /// The I/O boundary, injected so the failure paths are exercisable
    /// without stores, Keychain, real SSH or a live tunnel.
    struct Environment {
        var records: @MainActor () -> [ConnectionRecord]
        var update: @MainActor (ConnectionRecord) -> Void
        /// The user's rule for a protocol, and the connections excepted from
        /// every rule (Settings → Room auto-update). Read at each pass, so a
        /// change there applies from the next one.
        var rule: @MainActor (String) -> RoomRotationRule = {
            SettingsStore.shared.roomRotationRule(for: $0)
        }
        /// When in the day the protocol's rule may act.
        var window: @MainActor (String) -> RoomRotationWindow = {
            SettingsStore.shared.roomRotationWindow(for: $0)
        }
        var exceptions: @MainActor () -> Set<UUID> = {
            SettingsStore.shared.roomRotationExceptions
        }
        /// Whether a saved server this phone administers produced the record.
        var isManaged: @MainActor (ConnectionRecord) -> Bool
        var target: @MainActor (ConnectionRecord) -> Target?
        /// The normalized VK call link the server config takes.
        var createVKRoom: @MainActor () async throws -> String
        /// A SaluteJazz room reference, `<code>:<password>`.
        var createSaluteRoom: @MainActor () async throws -> String
        /// A new room on the Jitsi service of the room it is given. No network:
        /// the room comes into being when the server joins it.
        var createJitsiRoom: @MainActor (String) -> String
        /// Whether the app can make an MTS Link meeting at all: it has learned
        /// how and holds the sign-in (MTSLinkRoomService.canCreateRooms). Gates
        /// the rule — a schedule without something to rotate WITH does nothing.
        var canCreateMTSLinkRoom: @MainActor () -> Bool = { MTSLinkRoomService.canCreateRooms }
        /// A new MTS Link meeting, given the room that is current: the app
        /// replays, from inside the signed-in page, the request the owner
        /// showed it (MTSLinkReplay). The old meeting is NOT deleted — no
        /// delete request is known — and a refusal (the plan's cap, a signed-out
        /// account) throws, so the old room stays.
        var createMTSLinkRoom: @MainActor (String) async throws -> String = { current in
            try await MTSLinkRoomService.createRoom(current: current)
        }
        var applyRoom: @MainActor (Target, InstallOptions) async throws -> String?
        var engagedRecord: @MainActor () -> ConnectionRecord?
        /// Whether the live session is a connected SOCKS5 one, whose traffic
        /// the app can see.
        var isConnectedProxy: @MainActor () -> Bool
        var lastActivity: @MainActor () -> Date?
        var disconnect: @MainActor () -> Void
        var connect: @MainActor (ConnectionRecord) -> Void
        var now: @MainActor () -> Date = { Date() }
        /// The clock a window is read on: the phone's local time.
        var calendar: @MainActor () -> Calendar = { Calendar.current }
        var claimHost: @MainActor (UUID) -> Bool
        var releaseHost: @MainActor (UUID) -> Void

        // The silent daily account check.
        var vkSessionState: @MainActor () async -> AccountSessionVerdict = {
            guard let session = VKSessionStore.storedSession() else { return .unknown }
            return await VKCallRoomService.sessionState(session)
        }
        var mtsSessionState: @MainActor () async -> AccountSessionVerdict = {
            guard let session = MTSLinkSessionStore.storedSession() else { return .unknown }
            return await MTSLinkRoomService.sessionState(session)
        }
        var clearVKSession: @MainActor () -> Void = { VKSessionStore().clear() }
        var clearMTSSession: @MainActor () -> Void = { MTSLinkSessionStore().clear() }
        var lastAccountCheck: @MainActor () -> Date? = {
            UserDefaults.standard.object(forKey: RoomRotationCoordinator.accountCheckKey) as? Date
        }
        var saveAccountCheck: @MainActor (Date) -> Void = {
            UserDefaults.standard.set($0, forKey: RoomRotationCoordinator.accountCheckKey)
        }
    }

    /// When the silent account check last ran (nil = never). An internal
    /// clock, deliberately NOT a SettingsStore setting: the user has no
    /// reason to tune it.
    static let accountCheckKey = "olcrtc.room-rotation.account-check.v1"

    private let environment: Environment

    /// After a "sign in again" failure: when each connection may be retried.
    /// In-memory on purpose — a relaunched app re-learns the state from the
    /// service on its next attempt, and a crash must not persist a penalty.
    private var blockedUntil: [UUID: Date] = [:]

    /// Connections whose postponement is already in the log, so a due room
    /// that waits for a quiet tunnel says so once, not on every pass.
    private var postponeLogged: Set<UUID> = []

    /// Connections whose wait for their window is already in the log.
    private var windowWaitLogged: Set<UUID> = []

    /// Guards against two passes overlapping — the loop ticks on its own and
    /// the foreground pass can arrive beside it.
    private var running = false

    convenience init(connections: ConnectionStore, hosts: ServerHostStore, tunnel: TunnelManager) {
        let provisioner = Provisioner()
        self.init(environment: Environment(
            records: { connections.connections },
            update: { connections.update($0) },
            isManaged: { RoomRotationPolicy.isManaged($0, hosts: hosts.hosts) },
            target: { record in
                guard let host = hosts.hosts.first(where: { $0.canManage && $0.links(record.id) }),
                      let secret = hosts.secret(for: host),
                      // Automatic first trust is allowed; SSHRunner validates
                      // the actual presented key before applying anything.
                      (try? SSHHostKeyTrustStore.shared.prepare(host: host.host, port: host.port,
                          legacyPin: host.sshHostKeyPin)) != nil,
                      let container = TelemostRenewalCoordinator.containerName(for: record, host: host)
                else { return nil }
                return Target(host: host, secret: secret, container: container)
            },
            createVKRoom: { try await VKCallRoomService.createRoom().link },
            createSaluteRoom: { try await SaluteJazzRoomService.createRoom() },
            createJitsiRoom: { CarrierEndpoints.freshJitsiRoom(near: $0) },
            applyRoom: { target, options in
                try await provisioner.reconfigure(on: target.host, secret: target.secret,
                    containerName: target.container, options: options)
            },
            engagedRecord: { tunnel.engagedRecord },
            isConnectedProxy: { tunnel.state.isConnected && tunnel.activeMode == .proxy },
            lastActivity: { TunnelManager.lastTunnelActivityDate },
            disconnect: { tunnel.disconnect() },
            connect: { tunnel.connect(record: $0) },
            claimHost: { Provisioner.tryEnterHost($0) },
            releaseHost: { Provisioner.leaveHost($0) }))
    }

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: Entry points

    /// Long-lived loop started from MainTabView. Sleeps and re-checks rather
    /// than returning when there is nothing to do — an id-less `.task` never
    /// restarts, so returning would end rotation for the rest of the session.
    func run() async {
        while !Task.isCancelled {
            await checkNow()
            try? await Task.sleep(for: .seconds(Int(passInterval())))
        }
    }

    /// How long until the next pass: the Telemost renewal's cadence (the
    /// answer changes as time passes, and the decision itself costs no I/O),
    /// shorter while a rule has a window so a one-hour window is not missed.
    /// Read before every sleep, so a window chosen in Settings applies from
    /// the next pass.
    func passInterval() -> TimeInterval {
        var rules: [String: RoomRotationRule] = [:]
        var windows: [String: RoomRotationWindow] = [:]
        for carrier in RoomRotationRule.carriers {
            rules[carrier] = environment.rule(carrier)
            windows[carrier] = environment.window(carrier)
        }
        return RoomRotationPolicy.passInterval(rules: rules, windows: windows)
    }

    /// One pass: the silent account check (gated to once a day on its own
    /// clock), then every connection this phone administers whose protocol is
    /// on a schedule, that the user has not excepted, and whose room is due.
    /// Also called when the app comes back to the foreground, where the
    /// interesting case is a phone that spent the night asleep with the
    /// interval already burned through.
    func checkNow() async {
        guard !running else { return }
        running = true
        defer { running = false }

        await checkAccounts()

        let exceptions = environment.exceptions()
        // Read once per pass, like the rules and the exceptions: whether MTS
        // Link has a create request to replay gates its schedule
        // (RoomRotationRule.allowed).
        let mtslinkCanCreate = environment.canCreateMTSLinkRoom()
        for record in environment.records() {
            if Task.isCancelled { return }
            guard case .olcrtc(let params) = record.details,
                  let hours = RoomRotationPolicy.scheduledHours(
                      for: record, rule: environment.rule(params.carrier), exceptions: exceptions,
                      mtslinkCanCreate: mtslinkCanCreate),
                  environment.isManaged(record) else { continue }
            if params.roomCreatedAt == nil {
                // The Telemost renewal's rule: an unrecorded age is started,
                // not guessed. One quiet stamp, then the interval applies.
                var moved = params
                moved.roomCreatedAt = environment.now()
                var stamped = record
                stamped.details = .olcrtc(moved)
                environment.update(stamped)
                LogStore.shared.log(.provisioning,
                    "Room rotation: \(record.displayName) has no recorded room age; counting its interval from now")
                continue
            }
            let now = environment.now()
            guard !RoomRotationPolicy.isBlocked(blockedUntil: blockedUntil[record.id], now: now) else { continue }

            let riding = RoomRotationPolicy.isRiding(live: environment.engagedRecord(),
                                                     record: record, params: params)
            let busy = riding && RoomRotationPolicy.isTunnelBusy(
                activityIsObservable: environment.isConnectedProxy(),
                lastActivity: environment.lastActivity(), now: now)
            switch RoomRotationPolicy.decide(roomCreatedAt: params.roomCreatedAt,
                                             intervalHours: hours, now: now, tunnelBusy: busy,
                                             window: environment.window(params.carrier),
                                             calendar: environment.calendar()) {
            case .notDue:
                postponeLogged.remove(record.id)
                windowWaitLogged.remove(record.id)
            case .waitForWindow:
                if windowWaitLogged.insert(record.id).inserted {
                    LogStore.shared.log(.provisioning,
                        "Room rotation: \(record.displayName) is due — waiting for its time window")
                }
            case .postpone:
                windowWaitLogged.remove(record.id)
                if postponeLogged.insert(record.id).inserted {
                    LogStore.shared.log(.provisioning,
                        "Room rotation: \(record.displayName) is due, but the tunnel is in use — waiting for a quiet moment")
                }
            case .rotate:
                postponeLogged.remove(record.id)
                windowWaitLogged.remove(record.id)
                await rotate(record, params: params)
            case .force:
                postponeLogged.remove(record.id)
                windowWaitLogged.remove(record.id)
                LogStore.shared.log(.provisioning,
                    "Room rotation: \(record.displayName) has waited \(Int(RoomRotationPolicy.busyGrace / 3600)) h past its due time — replacing the room although the tunnel is in use")
                await rotate(record, params: params)
            }
        }
    }

    // MARK: Rotating one room

    /// At most ONE room per connection per pass: the loop calls this once per
    /// record and only for the primary room, and the lanes (`extraRooms`) are
    /// deliberately left alone — a lane carries no creation stamp of its own,
    /// and restarting every container on one server in a single unattended
    /// pass is the thundering herd the per-pass rule exists to avoid.
    private func rotate(_ record: ConnectionRecord, params: OlcrtcConnection) async {
        guard let target = environment.target(record) else {
            LogStore.shared.log(.provisioning,
                "Room rotation: \(record.displayName) skipped — no linked server here can take the new room")
            return
        }
        guard !Task.isCancelled, environment.claimHost(target.host.id) else {
            LogStore.shared.log(.provisioning,
                "Room rotation: \(record.displayName) deferred — another operation owns the server")
            return
        }
        defer { environment.releaseHost(target.host.id) }

        // Stamp the START of creation (the renewal's rule): never overstate
        // the new room's age budget with a slow SSH apply behind it.
        let createdAt = environment.now()
        let roomID: String
        do {
            switch params.carrier {
            case "vkcalls":
                roomID = try await environment.createVKRoom()
            case "salutejazz":
                roomID = try await environment.createSaluteRoom()
            case "mtslink":
                roomID = try await environment.createMTSLinkRoom(params.roomID)
            case "jitsi":
                roomID = environment.createJitsiRoom(params.roomID)
            default:
                return   // a protocol without a room creator has no schedule to follow
            }
            try Task.checkCancellation()
        } catch {
            if Self.needsSignIn(error) {
                blockedUntil[record.id] = environment.now()
                    .addingTimeInterval(RoomRotationPolicy.signInRetryDelay)
                LogStore.shared.log(.provisioning,
                    "Room rotation: \(record.displayName) needs a sign-in again — leaving it alone for 24 h")
            } else if !Task.isCancelled {
                LogStore.shared.log(.provisioning,
                    "Room rotation: creating a room for \(record.displayName) failed (\(error.localizedDescription))")
            }
            return
        }

        // The user may have edited or deleted the record while the service
        // was answering; a stale snapshot must not overwrite their edit.
        guard environment.records().first(where: { $0.id == record.id })?.details == record.details else {
            LogStore.shared.log(.provisioning,
                "Room rotation: \(record.displayName) changed while its room was being created — new room discarded")
            return
        }

        let options = InstallOptions(carrier: params.carrier, transport: params.transport, roomID: roomID)
        do {
            let uri = try await environment.applyRoom(target, options)
            // The URI is emitted AFTER the restart. Nil, malformed or
            // mismatching output cannot confirm the rotation, even if SSH
            // returned — the same bar a manual change is held to.
            guard TelemostRenewalCoordinator.confirms(uri: uri, roomID: roomID, params: params) else {
                throw ConfirmationError.unconfirmed
            }
        } catch {
            // A lost SSH reply proves neither success nor failure of the
            // remote write. The record keeps its current room, the log says
            // exactly that, and the next pass — or a manual room change —
            // reconciles whatever the server actually did.
            LogStore.shared.log(.provisioning,
                "Room rotation: the new room for \(record.displayName) is not confirmed (\(error.localizedDescription)) — the record keeps its current room")
            return
        }

        guard var updated = environment.records().first(where: { $0.id == record.id }),
              updated.details == record.details else { return }
        var moved = params
        moved.roomID = roomID
        moved.roomCreatedAt = createdAt
        updated.details = .olcrtc(moved)
        environment.update(updated)
        LogStore.shared.log(.provisioning,
            "Room rotation: \(record.displayName) moved to a fresh room")

        // Only replace the tunnel if it STILL belongs to this record. Never
        // undo a user's disconnect or switch during the awaited operation —
        // the same guard the Telemost renewal reconnects under.
        if environment.engagedRecord()?.id == record.id {
            environment.disconnect()
            if !Task.isCancelled { environment.connect(updated) }
        }
    }

    private enum ConfirmationError: Error { case unconfirmed }

    /// The services' "sign in again" answers, one question.
    private static func needsSignIn(_ error: Error) -> Bool {
        (error as? VKCallRoomError)?.needsSignIn == true
            || (error as? MTSLinkRoomError)?.needsSignIn == true
    }

    // MARK: The silent account check
    //
    // Always on, once a day, on the foreground pass: the stored sessions are
    // verified against their services, and a session the service has
    // DEFINITIVELY refused is unlinked — the Accounts screen then says
    // "signed out" instead of a claim the app cannot back, which is this
    // app's substitute for the local notification it has no framework for.
    // Only a definitive rejection acts: "no answer" is not a verdict, and
    // unlinking a good session over a network blip would be worse than a
    // stale row. Yandex stays implicit — the Telemost renewal surfaces its
    // expiry on its own.
    private func checkAccounts() async {
        let now = environment.now()
        if let last = environment.lastAccountCheck(),
           now.timeIntervalSince(last) < RoomRotationPolicy.accountCheckInterval { return }
        environment.saveAccountCheck(now)

        if VKSessionStore.hasStoredSession() {
            switch await environment.vkSessionState() {
            case .rejected:
                environment.clearVKSession()
                LogStore.shared.log(.provisioning,
                    "VK: the stored session is no longer valid — sign in again (Settings → Accounts)")
            case .alive:
                LogStore.shared.log(.provisioning, "VK: the stored session is still valid")
            case .unknown:
                break   // no answer is not a verdict; the next day tries again
            }
        }
        if MTSLinkSessionStore.hasStoredSession() {
            switch await environment.mtsSessionState() {
            case .rejected:
                environment.clearMTSSession()
                LogStore.shared.log(.provisioning,
                    "MTS Link: the stored session is no longer valid — sign in again (Settings → Accounts)")
            case .alive:
                LogStore.shared.log(.provisioning, "MTS Link: the stored session is still valid")
            case .unknown:
                break
            }
        }
    }
}
