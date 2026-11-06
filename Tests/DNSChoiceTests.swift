import XCTest
@testable import olcrtc_ios

// One DNS setting, three places it is used: the core on the phone gets a
// fallback behind a resolver the core cannot fall back from by itself, and
// everything that runs on the VPS gets a resolver it can reach from there.

final class DNSChoiceTests: XCTestCase {

    func testAPublicResolverReachesThePhoneCoreAsIs() {
        XCTAssertEqual(DNSChoice.forPhoneCore("1.1.1.1:53"), "1.1.1.1:53")
        XCTAssertEqual(DNSChoice.forPhoneCore("8.8.8.8:53"), "8.8.8.8:53")
        XCTAssertEqual(DNSChoice.forPhoneCore("9.9.9.9"), "9.9.9.9")
    }

    func testAnyOtherResolverGetsCloudflareBehindIt() {
        XCTAssertEqual(DNSChoice.forPhoneCore("77.88.8.8:53"), "77.88.8.8:53,1.1.1.1:53")
        XCTAssertEqual(DNSChoice.forPhoneCore("213.87.0.1:53"), "213.87.0.1:53,1.1.1.1:53")
        XCTAssertEqual(DNSChoice.forPhoneCore("[2a02:6b8::feed:0ff]:53"), "[2a02:6b8::feed:0ff]:53,1.1.1.1:53")
    }

    func testTheServerNeverGetsACarrierResolver() {
        for preset in AppConstants.ruCarrierDnsPresets {
            XCTAssertEqual(DNSChoice.forServer(preset.value), SettingsStore.Defaults.dnsServer, preset.value)
        }
        XCTAssertEqual(DNSChoice.forServer("77.88.8.8:53"), "77.88.8.8:53")
        XCTAssertEqual(DNSChoice.forServer("1.1.1.1:53"), "1.1.1.1:53")
    }

    func testTheVPNConfigKeepsTheFirstResolverForTheSystem() {
        let conn = OlcrtcConnection(carrier: "jitsi", transport: "datachannel", roomID: "https://meet.egovm.ru/r",
                                    key: String(repeating: "ab", count: 32), clientID: "c")
        let cfg = VPNConfig(from: conn, dns: "77.88.8.8:53", timeoutMs: 1000)
        XCTAssertEqual(cfg.dns, "77.88.8.8:53,1.1.1.1:53")
        XCTAssertEqual(cfg.dnsHost, "77.88.8.8")
        XCTAssertEqual(cfg.systemDNS, "77.88.8.8:53", "the system resolver stays a single address")
    }

    func testTheInstallSendsTheServerForm() {
        let saved = SettingsStore.shared.dnsServer
        defer { SettingsStore.shared.dnsServer = saved }
        SettingsStore.shared.dnsServer = "213.87.0.1:53"
        let env = SSHRunner.installEnv(InstallOptions(carrier: "jitsi", transport: "datachannel", roomID: "",
                                                      jitsiBaseURL: AppConstants.defaultJitsiBaseURL))
        XCTAssertTrue(env.contains("OLCRTC_DNS=1.1.1.1:53"), env)
    }
}
