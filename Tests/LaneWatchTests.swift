import XCTest
@testable import olcrtc_ios

/// The wait between tries to join a dropped-out lane again. The watch itself,
/// and the VPN extension's lane supervisor, need live runtimes and run only
/// on a device.
final class LaneWatchTests: XCTestCase {
    func testFirstTryWaitsTwoSeconds() {
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 0), 2)
    }

    func testWaitDoublesAfterEachFailedTry() {
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 2), 4)
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 4), 8)
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 8), 16)
    }

    func testWaitNeverExceedsTwoMinutes() {
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 32), 64)
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 64), 120)
        XCTAssertEqual(OlcrtcEngine.nextLaneDelay(after: 120), 120)
    }

    func testTheVPNExtensionWaitsAsProxyModeDoes() {
        var proxy: TimeInterval = 0
        var vpn: TimeInterval = 0
        for _ in 0..<8 {
            proxy = OlcrtcEngine.nextLaneDelay(after: proxy)
            vpn = VPNConfig.nextLaneDelay(after: vpn)
            XCTAssertEqual(vpn, proxy)
        }
        XCTAssertEqual(vpn, 120)
    }

    // A lane still joining after the start's budget (at least 45 s) is ended
    // and started again: a first join can wait forever for a peer that is in
    // a room the server set up anew.
    func testALaneStillJoiningPastTheStartBudgetIsStartedAgain() {
        XCTAssertEqual(VPNConfig.laneJoinLimit(timeoutMs: 60_000), 60)
        XCTAssertEqual(VPNConfig.laneJoinLimit(timeoutMs: 600_000), 600)
        XCTAssertEqual(VPNConfig.laneJoinLimit(timeoutMs: 5_000), 45, "a short start budget never cuts a join that short")
        XCTAssertEqual(VPNConfig.laneJoinLimit(timeoutMs: 0), 45, "the extension's 0 means the core default")
    }

    // A bonded lane that counts as in its room but receives nothing for
    // three minutes while the others carry has lost the room.
    func testALaneSilentWhileTheOthersCarryIsNamedOnce() {
        var watch = LaneSilenceWatch()
        XCTAssertEqual(watch.silentLanes(rx: [100, 100, 100], now: 0), [], "the first look is the baseline")
        var rx: [UInt64] = [100, 100, 100]
        var named: [Int] = []
        var now: TimeInterval = 0
        while now < LaneSilenceWatch.limit + 6 {
            now += 3
            rx[0] += 40_000   // lanes 1 and 2 carry, lane 3 brings nothing in
            rx[1] += 40_000
            named += watch.silentLanes(rx: rx, now: now)
        }
        XCTAssertEqual(named, [2], "named once, at the limit")
    }

    func testAnIdleSessionNamesNoLane() {
        var watch = LaneSilenceWatch()
        _ = watch.silentLanes(rx: [5, 5], now: 0)
        // Nothing moves on any lane for ten minutes: no proof of a dead one.
        XCTAssertEqual(watch.silentLanes(rx: [5, 5], now: 600), [])
        // A trickle on one lane, under the evidence, still proves nothing.
        XCTAssertEqual(watch.silentLanes(rx: [10_005, 5], now: 900), [])
    }

    func testCountersThatStartOverAreNotSilence() {
        var watch = LaneSilenceWatch()
        _ = watch.silentLanes(rx: [900_000, 900_000], now: 0)
        // A new bond client counts from zero: the lane's own drop is growth.
        XCTAssertEqual(watch.silentLanes(rx: [0, 0], now: 400), [])
        XCTAssertEqual(watch.silentLanes(rx: [400_000, 0], now: 450), [])
    }

    func testTheBondClientsLaneBytesAreRead() {
        XCTAssertEqual(LaneSilenceWatch.receivedBytes("10:20,0:5,7:0"), [10, 0, 7])
        XCTAssertNil(LaneSilenceWatch.receivedBytes(""))
        XCTAssertNil(LaneSilenceWatch.receivedBytes("10:20,x:5"))
        XCTAssertNil(LaneSilenceWatch.receivedBytes("10"))
    }
}
