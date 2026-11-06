import XCTest
@testable import olcrtc_ios

// Pure helpers behind two reliability/diagnostics features:
//   #440 wedge detection, #439 exit geo. The reconnect backoff that #438
//   jittered is now `ReconnectPolicy` (ReconnectBackoffTests).

@MainActor
final class RecoveryGeoTests: XCTestCase {

    // MARK: #440 — wedge detection

    func testSignatureMatching() {
        XCTAssertTrue(WedgeDetector.isFailureSignature("sid=5 openstream failed: timeout"))
        XCTAssertTrue(WedgeDetector.isFailureSignature("client reconnect attempt=2"))
        XCTAssertTrue(WedgeDetector.isFailureSignature("remote not ready"))
        XCTAssertFalse(WedgeDetector.isFailureSignature("traffic: session=abc addr=x in=1 out=2"))
        XCTAssertFalse(WedgeDetector.isFailureSignature("SOCKS5 server listening on 127.0.0.1:8808"))
    }

    func testTripsAtThresholdWithinWindow() {
        var d = WedgeDetector(threshold: 3, window: 10)
        XCTAssertFalse(d.record(line: "openstream failed", now: 100))
        XCTAssertFalse(d.record(line: "openstream failed", now: 101))
        XCTAssertTrue(d.record(line: "openstream failed", now: 102))   // 3rd within 10s → trip
    }

    func testOldFailuresPrunedOutOfWindow() {
        var d = WedgeDetector(threshold: 3, window: 10)
        XCTAssertFalse(d.record(line: "dial failed", now: 100))
        XCTAssertFalse(d.record(line: "dial failed", now: 105))
        // 100 is now outside the trailing 10s window (115-10=105), so only 2 remain.
        XCTAssertFalse(d.record(line: "dial failed", now: 115))
    }

    func testNonSignatureLinesDoNotAccumulate() {
        var d = WedgeDetector(threshold: 2, window: 10)
        XCTAssertFalse(d.record(line: "traffic: ...", now: 1))
        XCTAssertFalse(d.record(line: "handshake failed", now: 2))
        XCTAssertFalse(d.record(line: "traffic: ...", now: 3))
        XCTAssertTrue(d.record(line: "handshake failed", now: 4))     // 2 signatures → trip
    }

    func testFiresOncePerBurstThenResets() {
        var d = WedgeDetector(threshold: 2, window: 10)
        _ = d.record(line: "dial failed", now: 1)
        XCTAssertTrue(d.record(line: "dial failed", now: 2))          // trip
        XCTAssertFalse(d.record(line: "dial failed", now: 3))         // window cleared on trip
        XCTAssertTrue(d.record(line: "dial failed", now: 4))          // fresh burst trips again
    }

    // MARK: #445 (audit fix 6) — signatures refreshed against master's capped reconnect

    // Master's per-attempt reconnect failure warns (internal/client/link.go) all
    // share the "on reconnect failed" suffix — which the old "handshake failed"
    // signature did NOT substring-match — plus the smux and provider-callback warns.
    func testMasterReconnectFailureLinesMatch() {
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "handshake on reconnect failed (attempt 2): context deadline exceeded"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "peer confirmation on reconnect failed (attempt 1): timeout"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "wait for peer on reconnect failed (attempt 3): no answer"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "smux re-init failed (attempt 1): broken pipe"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "client reconnect: nobody in the room answered or sent a frame (reason=liveness)"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "control healthy peer=ab12 but the data plane has stopped sending — tearing the session down"))
        XCTAssertTrue(WedgeDetector.isFailureSignature(
            "client reconnect: the peer refused the handshake (reason=liveness) - waiting before another try"))
    }

    // "open stream failed" (with a space) matches no master log line and was
    // removed; the real line "OpenStream failed: %v" (tunnel.go) still matches
    // via the "openstream failed" signature.
    func testDeadOpenStreamSignatureRemoved() {
        XCTAssertFalse(WedgeDetector.isFailureSignature("sid=5 open stream failed: timeout"))
        XCTAssertTrue(WedgeDetector.isFailureSignature("sid=5 OpenStream failed: timeout"))
    }

    // The core's give-up line for a burst — "client reconnect: exhausted N
    // handshake attempts … pausing before the next try" — means a pause that
    // grows to minutes, so it must trip IMMEDIATELY, bypassing the window.
    func testExhaustedBurstTripsImmediately() {
        var d = WedgeDetector(threshold: 4, window: 10)
        let line = "client reconnect: exhausted 5 handshake attempts (reason=liveness) - pausing before the next try"
        XCTAssertTrue(WedgeDetector.isFatalSignature(line))
        XCTAssertTrue(d.record(line: line, now: 100))
    }

    // A fatal trip clears the window — a single follow-up failure must not
    // instantly re-fire the (idempotent, but noisy) restart.
    func testFatalTripClearsTheWindow() {
        var d = WedgeDetector(threshold: 3, window: 10)
        XCTAssertFalse(d.record(line: "openstream failed", now: 1))
        XCTAssertFalse(d.record(line: "openstream failed", now: 2))
        XCTAssertTrue(d.record(line: "… - pausing before the next try", now: 3))
        XCTAssertFalse(d.record(line: "openstream failed", now: 4))
    }

    // Ordinary failure signatures still window normally — a fatal line is the
    // only immediate trip.
    func testNonFatalSignaturesStillRequireTheThreshold() {
        var d = WedgeDetector(threshold: 4, window: 10)
        XCTAssertFalse(d.record(line: "handshake on reconnect failed (attempt 1): x", now: 1))
        XCTAssertFalse(d.record(line: "handshake on reconnect failed (attempt 2): x", now: 2))
        XCTAssertFalse(d.record(line: "smux re-init failed (attempt 3): x", now: 3))
        XCTAssertTrue(d.record(line: "client reconnect attempt=4 reason=liveness", now: 4))
    }

    // MARK: #439 — exit geo

    func testParseGeoFromIpinfoJSON() {
        let json = #"{"ip":"5.42.103.58","city":"Moscow","region":"Moscow","country":"RU","org":"AS9123 JSC TIMEWEB"}"#
        let geo = IPChecker.parseGeo(Data(json.utf8))
        XCTAssertEqual(geo, IPChecker.ExitGeo(ip: "5.42.103.58", city: "Moscow",
                                              country: "RU", org: "AS9123 JSC TIMEWEB"))
    }

    func testParseGeoNilWhenEmptyOrGarbage() {
        XCTAssertNil(IPChecker.parseGeo(Data("not json".utf8)))
        XCTAssertNil(IPChecker.parseGeo(Data("{}".utf8)))
    }

    func testExitGeoLineFormatting() {
        let full = IPChecker.exitGeoLine(.init(ip: "5.42.103.58", city: "Moscow",
                                               country: "RU", org: "AS9123 JSC TIMEWEB"))
        XCTAssertEqual(full, "→ exit = 5.42.103.58 (Moscow, RU · AS9123 JSC TIMEWEB)")
        // Sparse data still renders cleanly.
        XCTAssertEqual(IPChecker.exitGeoLine(.init(ip: "1.2.3.4", city: nil, country: "US", org: nil)),
                       "→ exit = 1.2.3.4 (US)")
        XCTAssertEqual(IPChecker.exitGeoLine(.init(ip: "1.2.3.4", city: nil, country: nil, org: nil)),
                       "→ exit = 1.2.3.4")
    }
}
