import Foundation

// MARK: - HealthFailure (#456)
//
// #456: raw engine / SSH / URLSession error text is engineering noise — the
// user's actual incident was the app printing "run public client / handshake
// client / read welcome" at them. This file turns those raw strings into a
// STABLE machine reason code (persisted in `NodeHealth.reason`) plus a human
// sentence and a concrete next action, so a failing row can offer "Recover
// connection" right where it failed.
//
// Everything here is pure and unit-tested (`Tests/HealthModelTests.swift`).
// The substring tables are first-match-wins and mirror the strings the PINNED
// core (olcos-core/olcrtc) and Citadel actually emit — re-audit them on every
// `Mobile.xcframework` bump, exactly like `WedgeDetector.signatures`.

/// #456: the stable failure vocabulary. Raw value is persisted, so NEVER rename
/// a case — add new ones instead (an unknown raw decodes to `.unknown`).
enum HealthReason: String, Codable, Sendable, CaseIterable {
    case keyMismatch, noPeer, roomInvalid, carrierRejected, networkDown,
         hostUnreachable, sshAuth, portBusy, vpnActive, containerStopped,
         timedOut, unknown,
         /// The configured DNS resolver (Settings → DNS) did not answer from
         /// this network. Says nothing about the server.
         dnsUnreachable,
         /// The server's core speaks an olcrtc protocol this app's core does
         /// not: it predates the cores both sides negotiate with. The fix is
         /// the server's Update action, which no inline button can run here.
         serverOutdated

    /// Short headline (used as `HealthDisplay.title` for `.broken`).
    var headline: String {
        switch self {
        case .keyMismatch:      return L10n.healthReasonKeyMismatchShort.localized()
        case .noPeer:           return L10n.healthReasonNoPeerShort.localized()
        case .roomInvalid:      return L10n.healthReasonRoomInvalidShort.localized()
        case .carrierRejected:  return L10n.healthReasonCarrierRejectedShort.localized()
        case .networkDown:      return L10n.healthReasonNetworkDownShort.localized()
        case .hostUnreachable:  return L10n.healthReasonHostUnreachableShort.localized()
        case .sshAuth:          return L10n.healthReasonSSHAuthShort.localized()
        case .portBusy:         return L10n.healthReasonPortBusyShort.localized()
        case .vpnActive:        return L10n.healthReasonVPNActiveShort.localized()
        case .containerStopped: return L10n.healthReasonContainerStoppedShort.localized()
        case .timedOut:         return L10n.healthReasonTimedOutShort.localized()
        case .dnsUnreachable:   return L10n.healthReasonDNSUnreachableShort.localized()
        case .serverOutdated:   return L10n.healthReasonServerOutdatedShort.localized()
        case .unknown:          return L10n.healthReasonUnknownShort.localized()
        }
    }

    /// The full human sentence — never a raw core log line.
    var message: String {
        switch self {
        case .keyMismatch:      return L10n.healthReasonKeyMismatch.localized()
        case .noPeer:           return L10n.healthReasonNoPeer.localized()
        case .roomInvalid:      return L10n.healthReasonRoomInvalid.localized()
        case .carrierRejected:  return L10n.healthReasonCarrierRejected.localized()
        case .networkDown:      return L10n.healthReasonNetworkDown.localized()
        case .hostUnreachable:  return L10n.healthReasonHostUnreachable.localized()
        case .sshAuth:          return L10n.healthReasonSSHAuth.localized()
        case .portBusy:         return L10n.healthReasonPortBusy.localized()
        case .vpnActive:        return L10n.healthReasonVPNActive.localized()
        case .containerStopped: return L10n.healthReasonContainerStopped.localized()
        case .timedOut:         return L10n.healthReasonTimedOut.localized()
        case .dnsUnreachable:   return L10n.healthReasonDNSUnreachable.localized()
        case .serverOutdated:   return L10n.healthReasonServerOutdated.localized()
        case .unknown:          return L10n.healthReasonUnknown.localized()
        }
    }

    /// The sentence for a connection this phone does not manage: the fix is
    /// not on its Servers tab, so it names whoever gave the link instead.
    func message(managedHere: Bool) -> String {
        guard !managedHere else { return message }
        switch self {
        case .keyMismatch:    return L10n.healthReasonKeyMismatchGuest.localized()
        case .serverOutdated: return L10n.healthReasonServerOutdatedGuest.localized()
        default:              return message
        }
    }

    /// The next thing the user can actually DO about it. nil ⇒ nothing to offer
    /// in-place (an SSH credential problem is fixed in the host editor; a live
    /// system VPN is turned off in the Config tab).
    var action: HealthAction? {
        switch self {
        case .keyMismatch:      return .recoverConnection
        case .roomInvalid:      return .checkRoom
        // #456 was: .checkRoom — but this state's own message names three causes
        // (server stopped, different room, key rotated by a reinstall) and
        // Recover connection is the one action that settles all three: it
        // re-reads the live server's room AND key. Checking the room by hand
        // fixes only one of them, and not the most likely one after a reinstall.
        case .noPeer:           return .recoverConnection
        case .containerStopped: return .startContainer
        case .portBusy:         return .openPortSettings
        case .dnsUnreachable:   return .openDNSSettings
        case .networkDown, .hostUnreachable, .carrierRejected, .timedOut, .unknown:
                                return .retry
        case .sshAuth, .vpnActive, .serverOutdated:
                                return nil
        }
    }
}

/// #456: the action a failing row offers inline. The VIEW decides how to run it
/// (ServersView already owns recover / reconfigure / start); this type only
/// names the offer so the model layer can suggest one without importing UI.
enum HealthAction: String, Equatable, Sendable {
    case recoverConnection, checkRoom, startContainer, openPortSettings, openDNSSettings, retry, verify

    var title: String {
        switch self {
        case .recoverConnection: return L10n.healthActionRecover.localized()
        case .checkRoom:         return L10n.healthActionCheckRoom.localized()
        case .startContainer:    return L10n.healthActionStart.localized()
        case .openPortSettings:  return L10n.healthActionPortSettings.localized()
        case .openDNSSettings:   return L10n.healthActionDNSSettings.localized()
        case .retry:             return L10n.healthActionRetry.localized()
        case .verify:            return L10n.healthActionVerify.localized()
        }
    }
}

/// #456: pure raw-string → reason mapping. First match wins — the ORDER of the
/// tests below is the contract (e.g. "readiness timed out" must resolve to
/// `.noPeer`, not to the generic `.timedOut`).
enum HealthFailureMapper {

    /// Maps a raw engine / URLSession error string to a reason.
    /// FIRST MATCH WINS — keep this order.
    static func reason(forRaw raw: String) -> HealthReason {
        let s = raw.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { s.contains($0) } }

        // 0a. The core names the cause of a failed first handshake itself
        //     (ghostlane-project/olcrtc internal/client/classify.go, surfaced as
        //     "handshake: <cause>: …"). Its words beat guessing from the error
        //     underneath: a wrong key still ends in "read welcome … timeout",
        //     which rule 0 would file as nobody answering.
        if s.contains("key does not match the peer") { return .keyMismatch }
        if s.contains("incompatible olcrtc protocol") { return .serverOutdated }
        if any(["peer did not answer the handshake", "no peer in room"]) { return .noPeer }
        // 0. A handshake that simply ran out of time is NOT a key problem: the
        //    hello went out and nobody in the room answered. Seen on a phone that
        //    imported a shared connection — the server log had no session from
        //    it at all, yet the app said "key no longer matches". Wrong key
        //    fails as a decrypt error / EOF (case 1), never as a timeout.
        if any(["read welcome", "handshake client", "send hello"])
            && any(["timeout", "timed out", "deadline exceeded", "context canceled"]) {
            return .noPeer
        }
        // 1. The user's own incident: the server was reinstalled, its key rotated,
        //    and the stored key no longer decrypts the welcome frame.
        if any(["read welcome", "handshake client", "handshake rejected",
                "record authentication failed", "bad record magic",
                "invalid key size", "challenge mismatch"]) { return .keyMismatch }
        // 2. Nobody answered in the room (server stopped, or a different room).
        //    MUST precede `.timedOut` — "readiness timed out" is a peer problem.
        if any(["readiness timed out", "stopped before becoming ready",
                "no peer"]) { return .noPeer }
        // 3. The room identifier itself is rejected.
        //    VK Calls words it "room url must be …" / "room url required";
        //    SaluteJazz "malformed room reference" / `expected "<code>:<password>"`;
        //    MTS Link "room must be the event join link (…/j/{owner}/{event})"
        //    / "the service has no such room" / "the event has no session to
        //    join" (olcos-core/olcrtc internal/auth/mtslink).
        if any(["invalid room url", "room not found", "room id is required",
                "room is required", "room url must", "room url required",
                "malformed room reference", "<code>:<password>",
                "event join link", "no such room", "has no session"]) { return .roomInvalid }
        // 3b. The configured resolver itself did not answer. The core resolves
        //    every provider / ICE host through Settings → DNS (a Go resolver
        //    dialling that one `IP:53`), and its failure reads
        //    "lookup <host> on 77.88.8.8:53: read udp …: i/o timeout". Seen on
        //    a second phone whose network does not reach the default Yandex
        //    resolver: the row said "Timed out" while Jitsi on the same phone
        //    worked; switching the resolver fixed it. MUST precede
        //    `.carrierRejected` ("telemost api: … lookup … i/o timeout" is not a
        //    refusal), `.networkDown` ("network is unreachable") and `.timedOut`.
        if s.contains("lookup ") && s.contains(":53")
            && any(["i/o timeout", "timed out", "timeout", "deadline exceeded",
                    "connection refused", "network is unreachable",
                    "no route to host", "server misbehaving"]) { return .dnsUnreachable }
        // 4. The conferencing service refused us (room gone / token wrong).
        //    MTS Link words a turned-away guest "the service did not accept
        //    the guest" (olcos-core/olcrtc internal/auth/mtslink).
        if any(["telemost api", "guest register", "join room", "get token",
                "api error", "auth provider not found", "unsupported provider",
                "did not accept the guest",
                " 403", " 401", "forbidden", "unauthorized"]) { return .carrierRejected }
        // 5. The phone has no usable internet — says NOTHING about the server.
        //    MUST precede `.hostUnreachable` ("network is unreachable").
        if any(["no such host", "network is unreachable", "no route to host",
                "appears to be offline", "internet connection", "dns"]) { return .networkDown }
        // 6. Local SOCKS port taken by another app.
        if any(["address already in use", "eaddrinuse",
                "no free local port"]) { return .portBusy }
        // 7. Something refused / is down at the far end.
        if any(["connection refused", "host is down", "unreachable"]) { return .hostUnreachable }
        // 8. Reached the network, got nothing back in time.
        if any(["context deadline exceeded", "timed out", "timeout"]) { return .timedOut }
        return .unknown
    }

    /// Maps an olcos-core health reason (engine/xray/health.go, forwarded as a
    /// `health:{"reason":…}` log line) to a reason. The core's vocabulary is a
    /// subset of `HealthReason`, `dnsUnreachable` included; anything newer
    /// reads as `.unknown` until this side learns it.
    static func reason(forXrayReason raw: String) -> HealthReason {
        HealthReason(rawValue: raw) ?? .unknown
    }

    /// Maps a raw SSH / provisioning error string to a reason. Mirrors the
    /// classification in `SSHRunner.classifySSHError` (which is NOT modified —
    /// this is a read-only mirror so the health layer never imports it).
    static func reason(forSSH raw: String) -> HealthReason {
        let s = raw.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { s.contains($0) } }
        if any(["authentication", "auth failed", "permission denied", "password",
                "unable to authenticate",
                "all authentication methods failed"]) { return .sshAuth }
        if any(["refused", "unreachable", "timed out", "no route"]) { return .hostUnreachable }
        return reason(forRaw: raw)
    }

    /// true ⇒ report as "couldn't check", NOT as "broken" (requirement 2: an
    /// unreachable VPS or a dead Wi-Fi must never read as a failed server).
    /// `.timedOut` is deliberately NOT inconclusive: the probe reached the
    /// network and nothing came back — that IS a node-level failure.
    static func isInconclusive(_ r: HealthReason) -> Bool {
        switch r {
        case .networkDown, .hostUnreachable, .sshAuth, .portBusy, .vpnActive, .unknown,
             .dnsUnreachable:
            return true
        case .keyMismatch, .noPeer, .roomInvalid, .carrierRejected,
             .containerStopped, .timedOut, .serverOutdated:
            return false
        }
    }

    /// Whether a failed connect can only fail again the same way, so the
    /// reconnect loop stops and shows it (ReconnectPolicy): a wrong key, a
    /// room that is gone, a core the server does not speak, or a carrier that
    /// refused access or no longer has the room (HTTP 401/403/404/406/410).
    /// A connection over several lanes stops only on what they all share —
    /// the key and the server's core: one lane's room says nothing of the
    /// others. `reason` nil ⇒ classified from `raw`.
    static func isPermanent(reason: HealthReason?, raw: String, severalLanes: Bool) -> Bool {
        let r = reason ?? self.reason(forRaw: raw)
        switch r {
        case .keyMismatch, .serverOutdated:
            return true
        case .roomInvalid:
            return !severalLanes
        case .carrierRejected:
            return !severalLanes && carrierRefusedForGood(raw)
        case .noPeer, .networkDown, .hostUnreachable, .sshAuth, .portBusy, .vpnActive,
             .containerStopped, .timedOut, .unknown, .dnsUnreachable:
            return false
        }
    }

    /// A carrier's answer that will not change on a retry: the room is gone
    /// or access is refused. A server error, a rate limit or a dropped
    /// connection will.
    private static func carrierRefusedForGood(_ raw: String) -> Bool {
        let s = raw.lowercased()
        if ["forbidden", "unauthorized", "not found", "gone", "not acceptable",
            "did not accept the guest", "auth provider not found", "unsupported provider"]
            .contains(where: { s.contains($0) }) { return true }
        // A bare status code, not part of a longer number, an address or a port.
        return s.range(of: #"(?<![0-9.:])(401|403|404|406|410)(?![0-9.:])"#,
                       options: .regularExpression) != nil
    }
}
