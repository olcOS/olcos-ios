import XCTest
@testable import olcrtc_ios

/// The app side of the Xray server install (olcos-core server/xray/install.sh):
/// its output contract, the scripts the app composes, the options a user may
/// type, and the add-server plan that carries Xray. The installer itself runs
/// offline in scripts/test_xray_server_script.py; nothing here dials a server.
final class XrayServerProvisioningTests: XCTestCase {

    private let link = "vless://0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab@203.0.113.7:443"
        + "?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com"
        + "&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0427f68370c8885d"
        + "&spx=%2F&type=tcp#olcOS-abc12345"

    // MARK: Installer output

    func testParsesAFreshInstall() throws {
        let output = """
        [olcos-xray] pulling ghcr.io/xtls/xray-core:26.3.27
        OLCOS_XRAY_URI=\(link)
        OLCOS_XRAY_CONTAINER=olcos-xray-abc12345
        OLCOS_XRAY_TARGET=www.example.com:443
        OLCOS_XRAY_ADOPTED=0
        OLCOS_XRAY_EXIT=0
        """
        let result = try SSHRunner.parseXrayInstall(output)
        XCTAssertEqual(result.uri, link)
        XCTAssertEqual(result.containerName, "olcos-xray-abc12345")
        XCTAssertEqual(result.target, "www.example.com:443")
        XCTAssertFalse(result.adopted)
        XCTAssertEqual(try XrayURI.parse(result.uri).params.sni, "www.example.com")
    }

    func testParsesAnAdoptedDeployment() throws {
        let output = "OLCOS_XRAY_URI=\(link)\nOLCOS_XRAY_CONTAINER=olcos-xray-wxyz5678\n"
            + "OLCOS_XRAY_TARGET=www.transip.nl:443\nOLCOS_XRAY_ADOPTED=1\n"
        XCTAssertTrue(try SSHRunner.parseXrayInstall(output).adopted)
    }

    func testTheInstallersOwnReasonIsTheError() {
        let output = "[olcos-xray] ERROR: TCP port 443 is already in use\n"
            + "OLCOS_XRAY_ERROR=TCP port 443 is already in use\nOLCOS_XRAY_EXIT=1\n"
        XCTAssertThrowsError(try SSHRunner.parseXrayInstall(output)) { error in
            XCTAssertEqual(error as? SSHRunner.XrayInstallError,
                           .server("TCP port 443 is already in use"))
        }
    }

    func testOutputWithoutAResultIsAnErrorCarryingTheLastLines() {
        let output = "bash: /tmp/olcos-xray-install.sh: No such file or directory\nOLCOS_XRAY_EXIT=127\n"
        XCTAssertThrowsError(try SSHRunner.parseXrayInstall(output)) { error in
            guard case .server(let reason) = error as? SSHRunner.XrayInstallError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(reason.contains("No such file"), reason)
        }
    }

    func testAContainerOutsideTheXrayFamilyIsNotAResult() {
        let output = "OLCOS_XRAY_URI=\(link)\nOLCOS_XRAY_CONTAINER=olcrtc-server-abc\n"
        XCTAssertThrowsError(try SSHRunner.parseXrayInstall(output))
    }

    // MARK: Status and removal

    func testParsesTheDeploymentList() {
        let output = "XRAY=olcos-xray-wxyz5678\tUp 7 hours\n"
            + "XRAY=olcos-xray-old\tExited (0) 2 days ago\n"
            + "XRAY=olcrtc-server-abc\tUp 1 hour\n"
            + "noise\n"
        let deployments = SSHRunner.parseXrayStatus(output)
        XCTAssertEqual(deployments.map(\.containerName), ["olcos-xray-wxyz5678", "olcos-xray-old"])
        XCTAssertTrue(ServersView.isUp(deployments[0].status))
        XCTAssertFalse(ServersView.isUp(deployments[1].status))
        XCTAssertEqual(SSHRunner.parseXrayStatus(""), [])
    }

    func testRemovalTouchesOnlyItsOwnDeployment() {
        let script = SSHRunner.xrayRemoveScript(containerName: "olcos-xray-wxyz5678")
        XCTAssertTrue(script.contains("podman rm -f 'olcos-xray-wxyz5678'"))
        XCTAssertTrue(script.contains("rm -rf '/opt/olcos-xray-wxyz5678'"))
        XCTAssertTrue(script.contains("OLCOS_XRAY_REMOVED=ok"))
        // Anything but olcos-xray-<lowercase letters and digits> is refused
        // outright: the name is also a path under /opt.
        for name in ["olcos-xray-a; rm -rf /", "olcos-xray-../etc", "olcrtc-server-abc", "olcos-xray-"] {
            let refused = SSHRunner.xrayRemoveScript(containerName: name)
            XCTAssertFalse(refused.contains("rm -rf"), name)
            XCTAssertTrue(refused.contains("exit 1"), name)
        }
    }

    func testRemoveAllProtocolsIncludesXray() {
        for script in [SSHRunner.uninstallScript(containerName: "olcrtc-server-abc"),
                       SSHRunner.uninstallScript(containerName: nil),
                       SSHRunner.deepUninstallScript(containerName: "olcrtc-server-abc", removeImage: false)] {
            XCTAssertTrue(script.contains("grep '^olcos-xray-'"))
            XCTAssertTrue(script.contains("rm -rf /opt/olcos-xray-*"))
        }
    }

    // MARK: Install command and options

    func testTheInstallCommandAlwaysReportsAndUsesTheServerAddress() {
        let host = ServerHost(label: "ams", host: "203.0.113.7")
        let command = SSHRunner.xrayInstallCommand(host: host, options: XrayInstallOptions())
        XCTAssertTrue(command.hasPrefix("OLCOS_XRAY_HOST=203.0.113.7 bash /tmp/olcos-xray-install.sh"))
        XCTAssertTrue(command.hasSuffix("echo \"OLCOS_XRAY_EXIT=$?\""))
        XCTAssertFalse(command.contains("OLCOS_XRAY_TARGET"))
        XCTAssertFalse(command.contains("OLCOS_XRAY_PORT"))
    }

    func testTypedOverridesReachTheInstallerOnlyWhenValid() {
        let host = ServerHost(label: "ams", host: "203.0.113.7")
        let custom = SSHRunner.xrayInstallCommand(
            host: host, options: XrayInstallOptions(target: " www.example.org ", port: "8443"))
        XCTAssertTrue(custom.contains("OLCOS_XRAY_TARGET=www.example.org"))
        XCTAssertTrue(custom.contains("OLCOS_XRAY_PORT=8443"))
        let invalid = SSHRunner.xrayInstallCommand(
            host: host, options: XrayInstallOptions(target: "not a host", port: "70000"))
        XCTAssertFalse(invalid.contains("OLCOS_XRAY_TARGET"))
        XCTAssertFalse(invalid.contains("OLCOS_XRAY_PORT"))
    }

    func testOptionValidation() {
        XCTAssertTrue(XrayInstallOptions().isValid, "empty means automatic")
        XCTAssertTrue(XrayInstallOptions(target: "www.example.com", port: "443").isValid)
        XCTAssertFalse(XrayInstallOptions(target: "example").isTargetValid)
        XCTAssertFalse(XrayInstallOptions(target: "https://example.com").isTargetValid)
        XCTAssertFalse(XrayInstallOptions(target: ".example.com").isTargetValid)
        XCTAssertFalse(XrayInstallOptions(port: "0").isPortValid)
        XCTAssertFalse(XrayInstallOptions(port: "443a").isPortValid)
    }

    func testTheInstallerShipsWithTheApp() throws {
        let script = try SSHRunner.loadXrayInstallScript()
        XCTAssertTrue(script.contains("OLCOS_XRAY_URI="))
        XCTAssertTrue(script.contains("OLCOS_XRAY_ADOPT"))
        XCTAssertTrue(script.contains("--restart=always"))
    }

    // MARK: Add-server plan

    func testAnXrayOnlyPlanIsAPlan() {
        var plan = AddServerCarrierPlan()
        XCTAssertFalse(plan.hasAnything)
        plan.xray = true
        XCTAssertTrue(plan.hasAnything)
        XCTAssertTrue(plan.isEmpty, "no call carrier")
        XCTAssertNil(plan.installOptions(rooms: AddServerRoomDraft()))
        plan.xrayOptions.port = "99999"
        XCTAssertFalse(plan.xrayOptionsValid)
    }

    @MainActor
    func testAnXrayOnlyPlanSkipsTheRoomStepAndCarriesItsOptions() throws {
        let flow = AddServerFlowController(otherLabels: [])
        flow.access.label = "ams"
        flow.access.host = "203.0.113.7"
        flow.access.password = "secret"
        flow.plan = AddServerCarrierPlan()
        flow.plan.xray = true
        flow.plan.xrayOptions.target = "www.example.org"
        flow.step = .protocols
        XCTAssertTrue(flow.canAdvance(from: .protocols))
        flow.advance()
        XCTAssertEqual(flow.step, .install, "nothing to ask on the Room step")
        flow.goBack()
        XCTAssertEqual(flow.step, .protocols)
        let outcome = try XCTUnwrap(flow.makeOutcome())
        XCTAssertNil(outcome.primary)
        XCTAssertTrue(outcome.extras.isEmpty)
        XCTAssertEqual(outcome.xray?.target, "www.example.org")
    }

    @MainActor
    func testACarrierPlanStillVisitsTheRoomStep() {
        let flow = AddServerFlowController(otherLabels: [])
        flow.plan = .defaultPlan
        flow.plan.xray = true
        flow.step = .protocols
        flow.advance()
        XCTAssertEqual(flow.step, .room)
    }

    // MARK: Card headline

    func testXrayKeepsAHostWithoutOlcrtcFromReadingAsNothingInstalled() {
        let display = HostDisplay.base(.imageReady)
        let plain = HostHeadline.reduce(display: display, reachable: true, lastProbeAge: 5, health: .never)
        guard case .noContainer = plain else { return XCTFail("expected noContainer, got \(plain)") }
        let withXray = HostHeadline.reduce(display: display, reachable: true, lastProbeAge: 5,
                                           health: .never, otherProtocols: true)
        guard case .health = withXray else { return XCTFail("expected health, got \(withXray)") }
    }

    func testTheHostLinksItsXrayRecord() {
        var host = ServerHost(label: "ams", host: "203.0.113.7")
        let id = UUID()
        XCTAssertFalse(host.links(id))
        host.xrayConnectionID = id
        XCTAssertTrue(host.links(id))
    }
}
