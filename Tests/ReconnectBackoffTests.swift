import XCTest
@testable import olcrtc_ios

// The reconnect policy both modes share (`ReconnectPolicy`, VPNConfig.swift)
// and the decisions the app's recovery loop (`TunnelManager.requestReconnect`)
// takes from it. The loop itself drives the gomobile engine and is
// integration-only; the schedule, what stops it, the record a reconnect dials
// and the attempt line are pure and pinned here.
//
// Policy: a fast phase of full jitter — each wait a random point in
// [0, min(60 s, 1 s·2ⁿ)], never under 0.5 s — for 7 tries, then a try every
// 60–120 s with no limit while the connection is wanted and a network is
// there. Only a permanent error stops it. A minute of stable connection
// starts the count over; a network that came back or changed is tried after
// 0.5–1 s. The Android app keeps the same numbers.

final class ReconnectBackoffTests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        SettingsStore.flushPendingWrites()
        super.tearDown()
    }

    // MARK: Fast phase — full jitter

    func testFastPhaseWaitIsAFullJitterUnderTheDoublingCeiling() {
        for attempt in 0..<ReconnectPolicy.fastAttempts {
            let ceiling = min(60, pow(2, Double(attempt)))
            XCTAssertEqual(ReconnectPolicy.delay(attempt: attempt, random: 1), ceiling, accuracy: 1e-9)
            XCTAssertEqual(ReconnectPolicy.delay(attempt: attempt, random: 0.5), max(0.5, ceiling / 2),
                           accuracy: 1e-9)
        }
    }

    func testFastPhaseNeverWaitsUnderHalfASecond() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 0, random: 0), 0.5)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 0, random: 0.2), 0.5)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 4, random: 0), 0.5)
    }

    func testTheFastPhaseEndsWhereTheCeilingReachesTheCap() {
        XCTAssertEqual(ReconnectPolicy.fastAttempts, 7)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: ReconnectPolicy.fastAttempts - 1, random: 1), 60)
        XCTAssertFalse(ReconnectPolicy.isSlowPhase(attempt: ReconnectPolicy.fastAttempts - 1))
        XCTAssertTrue(ReconnectPolicy.isSlowPhase(attempt: ReconnectPolicy.fastAttempts))
    }

    // MARK: Slow phase — no limit

    func testSlowPhaseTriesEveryOneToTwoMinutesWithoutEnd() {
        for attempt in [7, 8, 50, 10_000, Int.max] {
            XCTAssertEqual(ReconnectPolicy.delay(attempt: attempt, random: 0), 60)
            XCTAssertEqual(ReconnectPolicy.delay(attempt: attempt, random: 1), 120)
            XCTAssertEqual(ReconnectPolicy.delay(attempt: attempt, random: 0.5), 90)
        }
    }

    func testInputsAreClamped() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 3, random: 9), 8)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 3, random: -9), 0.5)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: -5, random: 1), 1, "a negative attempt is the first")
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 9, random: 7), 120)
        for attempt in 0...40 {
            for r in [0.0, 0.3, 0.999, 1.0] {
                let d = ReconnectPolicy.delay(attempt: attempt, random: r)
                XCTAssertTrue(d.isFinite)
                XCTAssertGreaterThanOrEqual(d, 0.5)
                XCTAssertLessThanOrEqual(d, 120)
            }
        }
    }

    // MARK: Network

    func testANetworkThatCameBackOrChangedIsTriedAfterHalfToOneSecond() {
        XCTAssertEqual(ReconnectPolicy.networkSettle(random: 0), 0.5)
        XCTAssertEqual(ReconnectPolicy.networkSettle(random: 0.5), 0.75)
        XCTAssertEqual(ReconnectPolicy.networkSettle(random: 1), 1)
        XCTAssertEqual(ReconnectPolicy.networkSettle(random: 5), 1)
    }

    // MARK: The count

    func testTheCountStartsOverOnlyAfterAMinuteOfStableConnection() {
        XCTAssertEqual(ReconnectPolicy.startingAttempt(previous: 5, heldFor: 10), 5)
        XCTAssertEqual(ReconnectPolicy.startingAttempt(previous: 5, heldFor: 59.9), 5)
        XCTAssertEqual(ReconnectPolicy.startingAttempt(previous: 5, heldFor: 60), 0)
        XCTAssertEqual(ReconnectPolicy.startingAttempt(previous: 5, heldFor: nil), 0)
        XCTAssertEqual(ReconnectPolicy.startingAttempt(previous: -3, heldFor: 1), 0)
    }

    func testTheAttemptLineNeverCountsPastItsTotal() {
        for attempt in 0..<ReconnectPolicy.fastAttempts {
            XCTAssertEqual(TunnelManager.reconnectAttemptNote(attempt: attempt, delay: 4),
                           "↻ attempt \(attempt + 1)/\(ReconnectPolicy.fastAttempts) in 4s")
        }
        for attempt in [7, 8, 300] {
            let line = TunnelManager.reconnectAttemptNote(attempt: attempt, delay: 90)
            XCTAssertTrue(line.hasPrefix("↻ attempt \(attempt + 1) in 90s"), line)
            XCTAssertFalse(line.contains("/"), line)
        }
    }

    // MARK: What stops it

    func testOnlyAWrongKeyAGoneRoomOrAnOutdatedServerStopIt() {
        for permanent: HealthReason in [.keyMismatch, .roomInvalid, .serverOutdated] {
            XCTAssertTrue(HealthFailureMapper.isPermanent(reason: permanent, raw: "", severalLanes: false),
                          "\(permanent)")
        }
        for transient: HealthReason in [.noPeer, .networkDown, .hostUnreachable, .timedOut, .dnsUnreachable,
                                        .portBusy, .unknown, .containerStopped, .vpnActive, .sshAuth] {
            XCTAssertFalse(HealthFailureMapper.isPermanent(reason: transient, raw: "x", severalLanes: false),
                           "\(transient)")
        }
    }

    func testACarrierRefusalStopsItOnlyWhenTheRoomIsGoneOrAccessRefused() {
        for raw in ["telemost api: status 404 Not Found", "join room: HTTP 410 Gone",
                    "guest register: 406 Not Acceptable", "get token: 403 forbidden",
                    "api error: 401 unauthorized", "the service did not accept the guest"] {
            XCTAssertTrue(HealthFailureMapper.isPermanent(reason: .carrierRejected, raw: raw, severalLanes: false), raw)
        }
        for raw in ["telemost api: status 502 Bad Gateway", "join room: connection reset by peer",
                    "get token: EOF", "api error: 429 too many requests",
                    "telemost api: dial tcp 10.0.0.1:4043: i/o timeout"] {
            XCTAssertFalse(HealthFailureMapper.isPermanent(reason: .carrierRejected, raw: raw, severalLanes: false), raw)
        }
    }

    func testWithoutAReasonTheRawTextDecides() {
        XCTAssertTrue(HealthFailureMapper.isPermanent(
            reason: nil, raw: "handshake: key does not match the peer", severalLanes: false))
        XCTAssertTrue(HealthFailureMapper.isPermanent(
            reason: nil, raw: "the service has no such room", severalLanes: false))
        XCTAssertFalse(HealthFailureMapper.isPermanent(
            reason: nil, raw: "olcRTC runtime readiness timed out", severalLanes: false))
    }

    func testASeveralLaneConnectionStopsOnlyOnTheSharedKeyOrCore() {
        XCTAssertTrue(HealthFailureMapper.isPermanent(reason: .keyMismatch, raw: "", severalLanes: true))
        XCTAssertTrue(HealthFailureMapper.isPermanent(reason: .serverOutdated, raw: "", severalLanes: true))
        XCTAssertFalse(HealthFailureMapper.isPermanent(reason: .roomInvalid, raw: "", severalLanes: true),
                       "one lane's room says nothing of the others")
        XCTAssertFalse(HealthFailureMapper.isPermanent(reason: .carrierRejected, raw: "join room: 404 Not Found",
                                                       severalLanes: true))
    }

    // MARK: The record a reconnect dials

    private let key = String(repeating: "ab", count: 32)

    private func record(room: String, key: String? = nil) -> ConnectionRecord {
        ConnectionRecord(name: "ams · Jitsi", details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: room, key: key ?? self.key, clientID: "default")))
    }

    func testAReconnectDialsTheRecordAsItIsSavedNow() {
        let live = record(room: "https://meet.example.org/old")
        var saved = live
        saved.details = record(room: "https://meet.example.org/new").details
        XCTAssertEqual(TunnelManager.reconnectRecord(live: live, saved: saved), saved)
    }

    func testWithoutAUsableSavedCopyTheConnectTimeCopyStays() {
        let live = record(room: "https://meet.example.org/old")
        XCTAssertEqual(TunnelManager.reconnectRecord(live: live, saved: nil), live, "deleted meanwhile")
        let other = record(room: "https://meet.example.org/new")
        XCTAssertEqual(TunnelManager.reconnectRecord(live: live, saved: other), live, "another record")
        var locked = live
        locked.details = record(room: "https://meet.example.org/new", key: "").details
        XCTAssertEqual(TunnelManager.reconnectRecord(live: live, saved: locked), live,
                       "a copy whose key could not be read cannot connect")
    }
}
