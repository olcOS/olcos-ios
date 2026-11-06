import XCTest
@testable import olcrtc_ios

// A whole-server connection (several lanes, ServerBundle) that drops comes
// back as itself: it fails over to a single protocol or another server only
// after its fast phase and three slow tries, comes back once one of its rooms
// answers again, and its lanes rejoin a moment apart rather than all at once
// (two rooms on one carrier host fail together). The loops that act on these
// decisions drive the gomobile engine and are integration-only.

final class WholeServerRecoveryTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)

    private func single(_ carrier: String = "jitsi", room: String = "https://meet.example.org/a") -> ConnectionRecord {
        ConnectionRecord(name: "ams · \(carrier)", details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: "datachannel", roomID: room, key: key, clientID: "default")))
    }

    private func bundle() -> ConnectionRecord {
        var p = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                 roomID: "https://meet.example.org/a", key: key, clientID: "default",
                                 wbToken: "token-for-wb")
        p.bundleLanes = [OlcrtcLane(carrier: "salutejazz", transport: "datachannel", roomID: "abcd12:efgh3456"),
                         OlcrtcLane(carrier: "vkcalls", transport: "vp8channel", roomID: "https://vk.example.org/c"),
                         OlcrtcLane(carrier: "wbstream", transport: "datachannel", roomID: "wb-room-1")]
        p.bond = "203.0.113.7:9443"
        return ConnectionRecord(name: "ams", details: .olcrtc(p))
    }

    private func room(_ record: ConnectionRecord) -> String? {
        guard case .olcrtc(let p) = record.details else { return nil }
        return p.roomID
    }

    // MARK: When it fails over

    func testASingleProtocolHandsOverAfterThreeTries() {
        XCTAssertEqual(TunnelManager.failoverAfterAttempts(for: single()), 3)
    }

    func testAWholeServerConnectionHandsOverOnlyPastItsSlowTries() {
        let after = TunnelManager.failoverAfterAttempts(for: bundle())
        XCTAssertEqual(after, ReconnectPolicy.fastAttempts + 3)
        XCTAssertTrue(ReconnectPolicy.isSlowPhase(attempt: after - 1),
                      "the fast phase is over before it may leave")
    }

    // MARK: Coming back

    func testTheWayBackIsCheckedEveryThreeToFiveMinutes() {
        XCTAssertEqual(TunnelManager.returnHomeCheckDelay(random: 0), 180)
        XCTAssertEqual(TunnelManager.returnHomeCheckDelay(random: 1), 300)
        XCTAssertEqual(TunnelManager.returnHomeCheckDelay(random: 9), 300)
    }

    func testOnlyAWholeServerConnectionIsReturnedTo() {
        XCTAssertTrue(TunnelManager.shouldReturnHome(chosen: bundle(), live: single()))
        let home = bundle()
        XCTAssertFalse(TunnelManager.shouldReturnHome(chosen: home, live: home), "already home")
        XCTAssertFalse(TunnelManager.shouldReturnHome(chosen: single(), live: single("vkcalls", room: "x")))
        XCTAssertFalse(TunnelManager.shouldReturnHome(chosen: nil, live: single()))
        XCTAssertFalse(TunnelManager.shouldReturnHome(chosen: home, live: nil))
    }

    func testTheWayBackProbesEachRoomTheLiveSessionIsNotIn() {
        let home = bundle()
        let live = single("salutejazz", room: "abcd12:efgh3456")   // one of the bundle's rooms
        let probes = TunnelManager.returnHomeProbes(home: home, live: live)
        // A Jitsi room is probed last: its bridge is set up anew once a probe
        // leaves, and the room is unusable for about a minute after.
        XCTAssertEqual(probes.compactMap(room), ["https://vk.example.org/c", "wb-room-1", "https://meet.example.org/a"])
        for probe in probes {
            guard case .olcrtc(let p) = probe.details else { return XCTFail("not olcrtc") }
            XCTAssertEqual(p.lanes.count, 1, "one room per probe")
            XCTAssertNil(p.bond)
            XCTAssertEqual(p.clientID, TunnelManager.batchPingClientID(recordID: home.id),
                           "never the live session's identity")
            XCTAssertEqual(p.wbToken, p.carrier == "wbstream" ? "token-for-wb" : "",
                           "only WB Stream takes a token; VK Calls refuses one")
            XCTAssertEqual(p.key, key)
            XCTAssertEqual(probe.id, home.id)
        }
    }

    func testNoProbeWhenEveryRoomIsTheLiveSessions() {
        let home = single()
        XCTAssertTrue(TunnelManager.returnHomeProbes(home: home, live: single()).isEmpty)
        XCTAssertEqual(TunnelManager.returnHomeProbes(home: home, live: single("vkcalls", room: "x")).count, 1)
    }

    // MARK: Lanes rejoin apart

    func testLanesThatDropTogetherRejoinInTurn() {
        var previousEnd: TimeInterval = 0
        for rank in 0..<4 {
            let earliest = VPNConfig.laneRejoinOffset(rank: rank, random: 0)
            let latest = VPNConfig.laneRejoinOffset(rank: rank, random: 1)
            XCTAssertGreaterThanOrEqual(earliest, previousEnd, "rank \(rank) starts after the one before")
            XCTAssertEqual(latest - earliest, VPNConfig.laneRejoinSpacing, accuracy: 1e-9)
            previousEnd = latest
        }
        XCTAssertEqual(VPNConfig.laneRejoinOffset(rank: -2, random: 7), VPNConfig.laneRejoinSpacing)
    }

    func testALanesNextTryIsJitteredBelowItsBackoff() {
        XCTAssertEqual(VPNConfig.jitteredLaneDelay(8, random: 1), 8)
        XCTAssertEqual(VPNConfig.jitteredLaneDelay(8, random: 0), 4)
        XCTAssertEqual(VPNConfig.jitteredLaneDelay(120, random: 0.5), 90)
        XCTAssertEqual(VPNConfig.jitteredLaneDelay(8, random: -3), 4)
    }
}
