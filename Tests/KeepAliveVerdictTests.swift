import XCTest
@testable import olcrtc_ios

// How fast a dead session is noticed: keep-alive (and a sign from the core —
// the wedge detector, every lane out of its room) confirms a missed probe
// with a second one `ReconnectPolicy.confirmProbeDelay` later, and two misses
// in a row are dead — instead of three misses a whole interval apart. The
// probes themselves go through the live tunnel and are integration-only.

final class KeepAliveVerdictTests: XCTestCase {

    func testOneMissIsConfirmedSoonAndTwoInARowAreDead() {
        XCTAssertEqual(TunnelManager.keepAliveVerdict(consecutiveMisses: 0), .healthy)
        XCTAssertEqual(TunnelManager.keepAliveVerdict(consecutiveMisses: 1), .confirmSoon)
        XCTAssertEqual(TunnelManager.keepAliveVerdict(consecutiveMisses: 2), .dead)
        XCTAssertEqual(TunnelManager.keepAliveVerdict(consecutiveMisses: 7), .dead)
        XCTAssertEqual(TunnelManager.keepAliveVerdict(consecutiveMisses: -1), .healthy)
    }

    func testTheConfirmingProbeFollowsWithinSeconds() {
        XCTAssertEqual(ReconnectPolicy.confirmProbeDelay, 5)
        XCTAssertEqual(ReconnectPolicy.missesForDead, 2)
    }

    func testRecentTrafficSkipsTheProbe() {
        let now = Date()
        XCTAssertTrue(TunnelManager.keepAliveSkips(lastActivity: now.addingTimeInterval(-10), now: now,
                                                   interval: 30, missedAt: nil))
        XCTAssertFalse(TunnelManager.keepAliveSkips(lastActivity: now.addingTimeInterval(-40), now: now,
                                                    interval: 30, missedAt: nil))
        XCTAssertFalse(TunnelManager.keepAliveSkips(lastActivity: nil, now: now, interval: 30, missedAt: nil))
        // A busy window reserved ahead (a speed test) skips too.
        XCTAssertTrue(TunnelManager.keepAliveSkips(lastActivity: now.addingTimeInterval(120), now: now,
                                                   interval: 30, missedAt: nil))
    }

    func testOnlyTrafficAfterAMissCanSkipItsConfirmation() {
        let now = Date()
        let missed = now.addingTimeInterval(-5)
        XCTAssertFalse(TunnelManager.keepAliveSkips(lastActivity: now.addingTimeInterval(-10), now: now,
                                                    interval: 30, missedAt: missed),
                       "traffic from before the miss proves nothing about now")
        XCTAssertTrue(TunnelManager.keepAliveSkips(lastActivity: now.addingTimeInterval(-2), now: now,
                                                   interval: 30, missedAt: missed))
    }
}
