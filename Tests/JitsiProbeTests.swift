import XCTest
@testable import olcrtc_ios

// The add-server wizard asks the VPS which public Jitsi instances work before
// it installs. The script is read-only and quotes nothing it did not
// validate; the parser keeps only well-formed lines; the pick follows the
// candidate order and takes only instances that served config.js, accepted
// the XMPP WebSocket handshake and let guests in.

final class JitsiProbeTests: XCTestCase {

    func testParsesTheProbeLines() {
        let output = """
        OLCOS_JITSI webinar.knomary.dev 200 404 open
        OLCOS_JITSI meet.jit.si 200 101 token
        OLCOS_JITSI meet.mamba.group 200 101 open
        OLCOS_JITSI jitsi.etudevs.ru 000 000 open
        OLCOS_JITSI meet.example 200 101 guest-domain
        some unrelated line
        OLCOS_JITSI broken line
        OLCOS_JITSI_DONE
        """
        let probes = SSHRunner.parseJitsiProbes(output)
        XCTAssertEqual(probes.map(\.host),
                       ["webinar.knomary.dev", "meet.jit.si", "meet.mamba.group", "jitsi.etudevs.ru", "meet.example"])
        XCTAssertEqual(probes.filter(\.isUsable).map(\.host), ["meet.mamba.group"])
        XCTAssertEqual(probes[3].configStatus, 0, "an unanswered request reads as status 0")
        XCTAssertEqual(probes[4].access, .guestDomain)
    }

    func testThePickFollowsTheCandidateOrder() {
        let probes = [
            JitsiProbe(host: "b.example", configStatus: 200, websocketStatus: 101, access: .open),
            JitsiProbe(host: "a.example", configStatus: 200, websocketStatus: 101, access: .open),
            JitsiProbe(host: "c.example", configStatus: 200, websocketStatus: 404, access: .open),
        ]
        XCTAssertEqual(SSHRunner.bestJitsiHost(probes, order: ["c.example", "a.example", "b.example"]),
                       "a.example")
        XCTAssertNil(SSHRunner.bestJitsiHost(probes, order: ["c.example", "d.example"]))
        XCTAssertNil(SSHRunner.bestJitsiHost([], order: ["a.example"]))
    }

    func testOnlyOpenInstancesWithAWebSocketAreUsable() {
        XCTAssertFalse(JitsiProbe(host: "x", configStatus: 200, websocketStatus: 101, access: .token).isUsable)
        XCTAssertFalse(JitsiProbe(host: "x", configStatus: 200, websocketStatus: 101, access: .guestDomain).isUsable)
        XCTAssertFalse(JitsiProbe(host: "x", configStatus: 200, websocketStatus: 501, access: .open).isUsable)
        XCTAssertFalse(JitsiProbe(host: "x", configStatus: 0, websocketStatus: 101, access: .open).isUsable)
        XCTAssertTrue(JitsiProbe(host: "x", configStatus: 200, websocketStatus: 101, access: .open).isUsable)
    }

    func testTheScriptTakesOnlyPlainHostNames() {
        let script = SSHRunner.jitsiProbeScript(hosts: ["meet.mamba.group", "evil.example; rm -rf /",
                                                        "$(reboot).example", "UPPER.example", "m.catonmoon.com"])
        XCTAssertTrue(script.contains("for h in meet.mamba.group m.catonmoon.com; do"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("reboot"))
        XCTAssertFalse(script.contains("UPPER"))
        // The handshake the core itself makes, so 101 means it can join.
        XCTAssertTrue(script.contains("Sec-WebSocket-Protocol: xmpp"))
        XCTAssertTrue(script.contains("https://$h/xmpp-websocket"))
        XCTAssertTrue(script.contains("OLCOS_JITSI_DONE"))
        XCTAssertTrue(script.hasSuffix("exit 0"))
    }

    func testEveryCandidateCanBeProbedAndTheDefaultComesFirst() {
        for host in CarrierEndpoints.jitsiInstances {
            XCTAssertTrue(SSHRunner.isProbeableJitsiHost(host), host)
        }
        XCTAssertEqual(CarrierEndpoints.jitsiInstances.first,
                       CarrierEndpoints.host(fromRoomID: AppConstants.defaultJitsiBaseURL))
        // The old default answers only from Russian addresses: it stays on
        // offer for a VPS in Russia, after every instance that works abroad.
        XCTAssertEqual(CarrierEndpoints.jitsiInstances.last, "meet1.arbitr.ru")
    }
}
