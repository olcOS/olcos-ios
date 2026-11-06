import XCTest
@testable import olcrtc_ios

// VPN auto-connect: the rules iOS is given for every choice in Settings, and
// what auto-connect means for the saved profile — the key stays while iOS may
// start the tunnel by itself, and a stop by hand pauses it and scrubs as before.

@MainActor
final class VPNOnDemandTests: XCTestCase {

    private typealias Rule = VPNOnDemandPlan.Rule

    func testNothingChosenMeansNoAutoConnect() {
        XCTAssertNil(VPNOnDemandPlan.rules(cellular: false, wifi: .off, networks: ["Home"]))
        XCTAssertNil(VPNOnDemandPlan.rules(cellular: false, wifi: .only, networks: []),
                     "only-these with no networks turns nothing on")
    }

    func testMobileDataTurnsItOnAndElsewhereItStaysAsItIs() {
        XCTAssertEqual(VPNOnDemandPlan.rules(cellular: true, wifi: .off, networks: []),
                       [Rule(action: .connect, interface: .cellular), Rule(action: .ignore, interface: .any)])
    }

    func testOnlyTheListedNetworksTurnItOn() {
        XCTAssertEqual(VPNOnDemandPlan.rules(cellular: false, wifi: .only, networks: [" Office ", "Office", "Cafe"]),
                       [Rule(action: .connect, interface: .wifi, networks: ["Office", "Cafe"]),
                        Rule(action: .ignore, interface: .any)])
    }

    func testTrustedNetworksTurnItOffAndEveryOtherWiFiOn() {
        XCTAssertEqual(VPNOnDemandPlan.rules(cellular: true, wifi: .except, networks: ["Home"]),
                       [Rule(action: .disconnect, interface: .wifi, networks: ["Home"]),
                        Rule(action: .connect, interface: .wifi),
                        Rule(action: .connect, interface: .cellular),
                        Rule(action: .ignore, interface: .any)])
        XCTAssertEqual(VPNOnDemandPlan.rules(cellular: false, wifi: .any, networks: ["ignored"]),
                       [Rule(action: .connect, interface: .wifi), Rule(action: .ignore, interface: .any)])
    }

    // MARK: The saved profile

    private func config() -> VPNConfig {
        VPNConfig(from: OlcrtcConnection(carrier: "jitsi", transport: "datachannel", roomID: "room",
                                         key: String(repeating: "a", count: 64), clientID: "test"),
                  dns: "1.1.1.1", timeoutMs: 1_000, fallbackVP8FPS: 10, fallbackVP8Batch: 1)
    }

    private func keyIsKept(_ profile: LifecycleProfile) -> Bool {
        !((profile.configuration["keyHex"] as? String) ?? "").isEmpty
    }

    func testAutoConnectKeepsTheKeyAndAStopByHandPausesIt() async throws {
        let profile = LifecycleProfile()
        let vpn = VPNController(loadProfiles: { [profile] }, makeProfile: { profile })
        let rules = VPNOnDemandPlan.rules(cellular: true, wifi: .off, networks: [])
        try await vpn.start(config(), onDemand: rules)
        XCTAssertEqual(profile.onDemandRules, rules, "the profile is saved with the rules")

        profile.emit(.connected)
        profile.emit(.disconnected)   // iOS took it down on a network change
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(keyIsKept(profile), "iOS must be able to start it again without the app")

        profile.emit(.connected)      // and started it again by itself
        vpn.stop()
        try await vpn.stopAndWait()
        XCTAssertNil(profile.onDemandRules, "turning it off by hand pauses auto-connect")
        XCTAssertFalse(keyIsKept(profile), "with auto-connect paused the key is scrubbed as before")
    }

    func testWithoutAutoConnectTheKeyIsScrubbedAsBefore() async throws {
        let profile = LifecycleProfile()
        let vpn = VPNController(loadProfiles: { [profile] }, makeProfile: { profile })
        try await vpn.start(config())
        XCTAssertNil(profile.onDemandRules)
        profile.emit(.connected)
        profile.emit(.disconnected)
        let deadline = Date().addingTimeInterval(2)
        while keyIsKept(profile), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(keyIsKept(profile))
    }
}
