import XCTest
@testable import olcrtc_ios

// The Jitsi service check in the reconfigure and add-protocol sheets: the
// quick probe weeds out services that do not answer, then the installed core
// tries each of the rest with a real tunnel. The SSH run itself is
// integration-only: on 2026-10-10 the script ran on an NL VPS and reported
// meet.egovm.ru and meet.riddlerx.org working and meet.mamba.group stalling.

final class JitsiTunnelCheckTests: XCTestCase {

    func testParsesTheVerdictForItsHostOnly() {
        let output = """
        OLCOS_JITSI_TUNNEL other.example works 900000
        OLCOS_JITSI_TUNNEL meet.egovm.ru works 564504
        """
        XCTAssertEqual(SSHRunner.parseJitsiTunnel(output, host: "meet.egovm.ru"), .works(bytesPerSecond: 564504))
        XCTAssertEqual(SSHRunner.parseJitsiTunnel("OLCOS_JITSI_TUNNEL a.example stalls 0", host: "a.example"),
                       .stalls)
        XCTAssertEqual(SSHRunner.parseJitsiTunnel("OLCOS_JITSI_TUNNEL a.example nodata 0", host: "a.example"),
                       .noData)
        XCTAssertNil(SSHRunner.parseJitsiTunnel("OLCOS_JITSI_TUNNEL_ERROR=binary", host: "a.example"),
                     "no check ran: the caller falls back to what the probe said")
        XCTAssertNil(SSHRunner.parseJitsiTunnel("OLCOS_JITSI_TUNNEL a.example maybe 0", host: "a.example"))
    }

    func testTheProbeDecidesOnlyWhatItCan() {
        XCTAssertEqual(SSHRunner.probeVerdict(nil), .unreachable)
        XCTAssertNil(SSHRunner.probeVerdict(
            JitsiProbe(host: "a", configStatus: 200, websocketStatus: 101, access: .open)))
        XCTAssertEqual(SSHRunner.probeVerdict(
            JitsiProbe(host: "a", configStatus: 200, websocketStatus: 101, access: .token)), .needsLogin)
        XCTAssertEqual(SSHRunner.probeVerdict(
            JitsiProbe(host: "a", configStatus: 200, websocketStatus: 404, access: .open)), .unreachable)
        XCTAssertEqual(SSHRunner.probeVerdict(
            JitsiProbe(host: "a", configStatus: 0, websocketStatus: 0, access: .open)), .unreachable)
    }

    func testTheScriptUsesTheInstalledCoreAndCleansUp() {
        let script = SSHRunner.jitsiTunnelScript(containerName: "olcrtc-server-abc", instance: "meet.egovm.ru",
                                                 transport: "datachannel", port: 18871)
        XCTAssertTrue(script.contains("H=\"meet.egovm.ru\""))
        XCTAssertTrue(script.contains("PORT=18871"))
        XCTAssertTrue(script.contains("\"olcrtc-server-abc\""))
        XCTAssertTrue(script.contains("BIN=\"$DEPLOY_DIR/olcrtc\""))
        XCTAssertTrue(script.contains("transport: \\\"datachannel\\\""))
        XCTAssertTrue(script.contains("kill $CPID $SPID"))
        XCTAssertTrue(script.contains("rm -rf \"$D\""))
        XCTAssertFalse(script.contains("podman run"), "the running containers are never touched")
        XCTAssertFalse(script.contains("podman restart"))
        XCTAssertFalse(script.contains("pkill"))
    }

    func testTheScriptRefusesAHostItCannotQuote() {
        let script = SSHRunner.jitsiTunnelScript(containerName: "c", instance: "evil.example; rm -rf /",
                                                 transport: "datachannel", port: 18870)
        XCTAssertTrue(script.contains("H=\"\""))
        XCTAssertFalse(script.contains("rm -rf /"))
    }

    func testWorkingServicesComeFirstFastestFirst() {
        let verdicts: [String: JitsiTunnelCheck.Verdict] = [
            "a": .unreachable, "b": .works(bytesPerSecond: 100), "c": .noData,
            "d": .works(bytesPerSecond: 500), "e": .stalls,
        ]
        XCTAssertEqual(JitsiInstanceCheck.sorted(["a", "b", "c", "d", "e", "f"], by: verdicts),
                       ["d", "b", "f", "e", "c", "a"])
    }

    func testTheCheckSwitchesOnlyAwayFromAServiceThatFails() {
        let verdicts: [String: JitsiTunnelCheck.Verdict] = [
            "a": .stalls, "b": .works(bytesPerSecond: 100), "c": .works(bytesPerSecond: 300),
        ]
        XCTAssertEqual(JitsiInstanceCheck.autoPick(current: "a", verdicts: verdicts, order: ["a", "b", "c"]), "c")
        XCTAssertNil(JitsiInstanceCheck.autoPick(current: "b", verdicts: verdicts, order: ["a", "b", "c"]),
                     "a working service stays even when another is faster")
        XCTAssertNil(JitsiInstanceCheck.autoPick(current: "a", verdicts: ["a": .noData], order: ["a"]))
    }

    func testACustomServiceIsListedAndChecked() {
        XCTAssertEqual(JitsiInstanceCheck.candidates(current: "jitsi.example.org").first, "jitsi.example.org")
        XCTAssertEqual(JitsiInstanceCheck.candidates(current: "meet.egovm.ru"), CarrierEndpoints.jitsiInstances)
        XCTAssertEqual(JitsiInstanceCheck.candidates(current: nil), CarrierEndpoints.jitsiInstances)
    }

    func testTheDefaultServiceLeadsTheList() {
        XCTAssertEqual(AppConstants.defaultJitsiBaseURL, "https://meet.egovm.ru")
        XCTAssertEqual(CarrierEndpoints.jitsiInstances.first, "meet.egovm.ru")
        XCTAssertEqual(CarrierEndpoints.jitsiInstances.last, "meet1.arbitr.ru")
    }
}
