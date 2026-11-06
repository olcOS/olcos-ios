import XCTest
@testable import olcrtc_ios

// The resume check: what the proxy session does when the app runs again after
// it may have been suspended (a phone call). Only the pure decisions are tested
// here — when a check starts, what counts as a suspension, what the listener
// and tunnel answers lead to, and the log lines. The socket, the probe and the
// reconnect they drive are integration-only (a real listener and a device).

@MainActor
final class ResumeCheckTests: XCTestCase {

    private func shouldRun(trigger: ResumeCheckTrigger = .foreground,
                           away: Double? = 60,
                           state: ConnectionState = .connected,
                           mode: TunnelMode = .proxy,
                           hasRecord: Bool = true,
                           recovery: Bool = false,
                           running: Bool = false,
                           sinceLast: Double? = nil) -> Bool {
        TunnelManager.shouldRunResumeCheck(
            trigger: trigger, awaySeconds: away, state: state, mode: mode,
            hasRecord: hasRecord, recoveryRunning: recovery, checkRunning: running,
            secondsSinceLastCheck: sinceLast)
    }

    // MARK: when a check runs

    func testRunsOnForegroundAfterALongAbsence() {
        XCTAssertTrue(shouldRun(trigger: .foreground, away: 60))
    }

    func testForegroundAfterAShortAppSwitchDoesNotRun() {
        XCTAssertFalse(shouldRun(trigger: .foreground, away: 2))
        XCTAssertFalse(shouldRun(trigger: .foreground, away: nil))
        XCTAssertTrue(shouldRun(trigger: .foreground, away: TunnelManager.resumeCheckMinAwaySeconds))
    }

    func testAudioResumedAndClockGapRunWithoutAnAbsenceFigure() {
        XCTAssertTrue(shouldRun(trigger: .audioResumed, away: nil))
        XCTAssertTrue(shouldRun(trigger: .clockGap, away: nil))
    }

    func testOnlyAConnectedProxySessionIsChecked() {
        for state in [ConnectionState.disconnected, .connecting, .waitingForNetwork, .failed("x")] {
            XCTAssertFalse(shouldRun(trigger: .audioResumed, state: state), "\(state)")
        }
        XCTAssertFalse(shouldRun(trigger: .audioResumed, mode: .vpn))
    }

    func testNeverAfterAUserDisconnect() {
        XCTAssertFalse(shouldRun(trigger: .audioResumed, hasRecord: false))
    }

    func testNeverBesideARunningReconnectLoopOrCheck() {
        XCTAssertFalse(shouldRun(trigger: .audioResumed, recovery: true))
        XCTAssertFalse(shouldRun(trigger: .audioResumed, running: true))
    }

    func testTwoTriggersTogetherShareOneCheck() {
        XCTAssertFalse(shouldRun(trigger: .foreground, sinceLast: 1))
        XCTAssertTrue(shouldRun(trigger: .foreground,
                                sinceLast: TunnelManager.resumeCheckDebounceSeconds))
        // A clock stepped back must not silence the check for good.
        XCTAssertTrue(shouldRun(trigger: .foreground, sinceLast: -30))
    }

    // MARK: the suspension gap

    func testTimerWakingOnTimeIsNotASuspension() {
        XCTAssertFalse(TunnelManager.isSuspensionGap(elapsedSeconds: 30, expectedSeconds: 30))
        XCTAssertFalse(TunnelManager.isSuspensionGap(elapsedSeconds: 45, expectedSeconds: 30))   // coalescing slop
    }

    func testTimerWakingFarLaterIsASuspension() {
        XCTAssertTrue(TunnelManager.isSuspensionGap(elapsedSeconds: 120, expectedSeconds: 30))
        XCTAssertTrue(TunnelManager.isSuspensionGap(elapsedSeconds: 600, expectedSeconds: 60))
    }

    func testGapBoundaryIsTwiceTheIntervalPlusSlack() {
        let edge = 30 * 2 + TunnelManager.suspensionGapSlackSeconds
        XCTAssertFalse(TunnelManager.isSuspensionGap(elapsedSeconds: edge, expectedSeconds: 30))
        XCTAssertTrue(TunnelManager.isSuspensionGap(elapsedSeconds: edge + 1, expectedSeconds: 30))
    }

    func testNoIntervalMeansNoGap() {
        XCTAssertFalse(TunnelManager.isSuspensionGap(elapsedSeconds: 9_999, expectedSeconds: 0))
    }

    // MARK: probe and verdict

    func testProbeIsSkippedOnlyRightAfterVerifiedTraffic() {
        XCTAssertTrue(TunnelManager.shouldProbeTunnelOnResume(secondsSinceActivity: nil))
        XCTAssertTrue(TunnelManager.shouldProbeTunnelOnResume(secondsSinceActivity: 120))
        XCTAssertFalse(TunnelManager.shouldProbeTunnelOnResume(secondsSinceActivity: 1))
        // A reserved busy window (a speed test) parks the marker in the future.
        XCTAssertFalse(TunnelManager.shouldProbeTunnelOnResume(secondsSinceActivity: -60))
    }

    func testDeadListenerMeansRestartWhateverTheProbeSays() {
        XCTAssertEqual(TunnelManager.resumeCheckVerdict(listenerAnswers: false, tunnelVerified: nil), .listenerGone)
        XCTAssertEqual(TunnelManager.resumeCheckVerdict(listenerAnswers: false, tunnelVerified: true), .listenerGone)
    }

    func testFailedProbeOnALiveListenerMeansReconnect() {
        XCTAssertEqual(TunnelManager.resumeCheckVerdict(listenerAnswers: true, tunnelVerified: false), .tunnelDead)
    }

    func testAnsweringListenerAndProbeOrNoProbeIsHealthy() {
        XCTAssertEqual(TunnelManager.resumeCheckVerdict(listenerAnswers: true, tunnelVerified: true), .healthy)
        XCTAssertEqual(TunnelManager.resumeCheckVerdict(listenerAnswers: true, tunnelVerified: nil), .healthy)
    }

    // MARK: log lines

    func testStartLineSaysWhyAndHowLongTheAppWasAway() {
        let line = TunnelManager.resumeCheckStartMessage(trigger: .foreground, awaySeconds: 130)
        XCTAssertTrue(line.contains("foreground"))
        XCTAssertTrue(line.contains("2m10s"))
        XCTAssertTrue(TunnelManager.resumeCheckStartMessage(trigger: .audioResumed, awaySeconds: nil)
            .contains("audio interruption ended"))
        XCTAssertFalse(TunnelManager.resumeCheckStartMessage(trigger: .clockGap, awaySeconds: nil)
            .contains("away"))
    }

    func testListenerLinesNameThePortAndTheOutcome() {
        let alive = TunnelManager.resumeListenerMessage(port: 8808, alive: true)
        XCTAssertTrue(alive.contains("127.0.0.1:8808"))
        XCTAssertTrue(alive.contains("alive"))
        let gone = TunnelManager.resumeListenerMessage(port: 8808, alive: false)
        XCTAssertTrue(gone.contains("gone"))
        XCTAssertTrue(gone.contains("same port"))
    }

    func testTunnelLinesCoverEveryOutcome() {
        XCTAssertTrue(TunnelManager.resumeTunnelMessage(verified: true, anotherVPN: false).contains("tunnel alive"))
        XCTAssertTrue(TunnelManager.resumeTunnelMessage(verified: nil, anotherVPN: false).contains("no probe needed"))
        let failed = TunnelManager.resumeTunnelMessage(verified: false, anotherVPN: false)
        XCTAssertTrue(failed.contains("reconnecting at once"))
        XCTAssertFalse(failed.contains("another VPN"))
        XCTAssertTrue(TunnelManager.resumeTunnelMessage(verified: false, anotherVPN: true).contains("another VPN"))
    }

    func testInterruptionLines() {
        XCTAssertTrue(TunnelManager.interruptionBeganMessage(backgroundTimeGranted: true)
            .contains("asked iOS for background time"))
        XCTAssertTrue(TunnelManager.interruptionBeganMessage(backgroundTimeGranted: false)
            .contains("no background time"))
        XCTAssertTrue(TunnelManager.interruptionEndedMessage(seconds: 95).contains("after 1m35s"))
        XCTAssertFalse(TunnelManager.interruptionEndedMessage(seconds: nil).contains("after"))
    }
}
