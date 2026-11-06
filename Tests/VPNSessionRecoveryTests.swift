import Network
import XCTest
@testable import olcrtc_ios

// VPNSessionRecovery: when the VPN extension holds and when it joins the rooms
// again, under the same ReconnectPolicy as proxy mode — without a limit while
// the VPN is on. The extension's own side (the path monitor, the rejoin of a
// runtime, the data-path probes) needs a device and is integration-only.

final class VPNSessionRecoveryTests: XCTestCase {

    func testTheFirstPathIsOnlyTheBaseline() {
        var recovery = VPNSessionRecovery()
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
        XCTAssertFalse(recovery.offline)
    }

    func testALossHoldsOnceAndItsReturnRejoins() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertTrue(recovery.offline)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .none, "already holding")
        // Back on the same Wi-Fi: the rooms' paths went with the gap all the same.
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .rejoin)
        XCTAssertFalse(recovery.offline)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
    }

    func testAnotherNetworkTakingOverRejoins() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .none)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .rejoin)
    }

    func testANetworkGoneRightAfterTheStartHoldsAtOnce() {
        var recovery = VPNSessionRecovery()
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
    }

    func testFailuresFollowTheSharedPolicyAndNeverGiveUp() {
        var recovery = VPNSessionRecovery()
        var delays: [TimeInterval] = []
        for _ in 0..<12 { delays.append(recovery.afterFailure(random: 1)) }
        // The fast phase's full-jitter ceilings, then the slow phase's longest wait.
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 60, 120, 120, 120, 120, 120])
        XCTAssertEqual(recovery.attempts, 12)
        for attempt in 0..<20 {
            var probe = VPNSessionRecovery()
            for _ in 0..<attempt { _ = probe.afterFailure(random: 0) }
            XCTAssertEqual(probe.afterFailure(random: 0.3), ReconnectPolicy.delay(attempt: attempt, random: 0.3),
                           "try \(attempt) waits what proxy mode waits")
        }
    }

    func testAMinuteOfCarryingGivesTheTriesBack() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        _ = recovery.afterFailure(random: 0)
        _ = recovery.afterFailure(random: 0)
        recovery.carried(now: 100)
        recovery.carried(now: 100 + ReconnectPolicy.stableAfter - 1)
        XCTAssertEqual(recovery.attempts, 2, "a drop within the minute goes on counting")
        recovery.carried(now: 100 + ReconnectPolicy.stableAfter)
        XCTAssertEqual(recovery.attempts, 0)

        // A failure ends the carrying: the minute starts over at the next carry.
        _ = recovery.afterFailure(random: 0)
        recovery.carried(now: 500)
        _ = recovery.afterFailure(random: 0)
        recovery.carried(now: 500 + ReconnectPolicy.stableAfter)
        XCTAssertEqual(recovery.attempts, 2)
    }

    func testANewNetworkGivesTheTriesBack() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        _ = recovery.afterFailure(random: 0)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.attempts, 0)

        _ = recovery.afterFailure(random: 0)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.attempts, 0)
    }

    func testTheTryLineCountsTheFastPhaseOnly() {
        XCTAssertEqual(VPNSessionRecovery.tryNote(attempt: 0, delay: 0.6),
                       "joining the rooms again in 1 s (try 1 of \(ReconnectPolicy.fastAttempts))")
        XCTAssertEqual(VPNSessionRecovery.tryNote(attempt: ReconnectPolicy.fastAttempts, delay: 90),
                       "joining the rooms again in 90 s (try \(ReconnectPolicy.fastAttempts + 1), every 1-2 min while the VPN is on)")
    }

    func testARejoinIsProbedSoonerThanAStart() {
        XCTAssertLessThan(VPNSessionRecovery.rejoinGrace, VPNDataPathHealth.startupGrace)
        XCTAssertLessThan(ReconnectPolicy.networkSettleMax, VPNSessionRecovery.rejoinGrace)
    }
}
