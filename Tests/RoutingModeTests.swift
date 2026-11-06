import XCTest
@testable import olcrtc_ios

// Settings → Routing: the two modes are a persisted contract, and the direct
// list the engines take is built from the ready-made Russian sites and the
// user's own lines, in the core's syntax.

final class RoutingModeTests: XCTestCase {

    // Raw values are persisted; renaming one would silently reset saved preferences.
    func testRawValuesAreStable() {
        XCTAssertEqual(RoutingMode.allTunnel.rawValue, "allTunnel")
        XCTAssertEqual(RoutingMode.listDirect.rawValue, "listDirect")
        XCTAssertNil(RoutingMode(rawValue: "allDirect"), "the never-shipped kill switch is gone")
    }

    func testBothModesHaveDistinctTitles() {
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }
        SettingsStore.shared.language = "en"
        XCTAssertEqual(RoutingMode.allCases.count, 2)
        XCTAssertFalse(RoutingMode.allTunnel.title.isEmpty)
        XCTAssertNotEqual(RoutingMode.allTunnel.title, RoutingMode.listDirect.title)
    }

    // MARK: The direct list

    func testEverythingThroughTheTunnelTakesNoList() {
        XCTAssertEqual(DirectRoutes.effective(mode: .allTunnel, russian: true, own: "example.com"), "")
    }

    func testTheListJoinsTheRussianSitesAndTheUsersOwn() {
        let text = DirectRoutes.effective(mode: .listDirect, russian: true, own: "example.com\ndomain:ru")
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("domain:ru"))
        XCTAssertTrue(lines.contains("domain:xn--p1ai"), ".рф is listed in its punycode form")
        XCTAssertTrue(lines.contains("domain:example.com"))
        XCTAssertEqual(lines.filter { $0 == "domain:ru" }.count, 1, "a rule the list already has is not repeated")
        XCTAssertEqual(DirectRoutes.effective(mode: .listDirect, russian: false, own: "example.com"),
                       "domain:example.com")
    }

    func testTheUsersLinesBecomeTheCoresSyntax() {
        let parsed = DirectRoutes.parse("""
            # my sites
            Example.COM
            https://bank.example.org/login?x=1
            *.cdn.example.net
            full:api.example.com
            10.0.0.0/8
            203.0.113.7
            2001:db8::/32

            """)
        XCTAssertEqual(parsed.rules, ["domain:example.com", "domain:bank.example.org", "domain:cdn.example.net",
                                      "full:api.example.com", "10.0.0.0/8", "203.0.113.7", "2001:db8::/32"])
        XCTAssertNil(parsed.badLine)
    }

    func testTheFirstLineThatIsNoSiteIsNamed() {
        let parsed = DirectRoutes.parse("example.com\nnot a site\n300.1.2.3/40\nok.example")
        XCTAssertEqual(parsed.badLine, 2)
        XCTAssertEqual(parsed.rules.first, "domain:example.com")
        XCTAssertEqual(parsed.rules.last, "domain:ok.example", "a bad line is skipped, not the rest")
        XCTAssertEqual(DirectRoutes.parse("10.0.0.0/33").badLine, 1)
    }

    func testTheRussianListIsInTheCoresSyntax() {
        for rule in DirectRoutes.russian {
            XCTAssertTrue(rule.hasPrefix("domain:"), rule)
            XCTAssertEqual(DirectRoutes.parse(rule).rules, [rule], rule)
        }
    }

    func testTheVPNExtensionGetsTheList() throws {
        var config = VPNConfig(carrier: "jitsi", transport: "datachannel", roomID: "r", clientID: "c",
                               keyHex: String(repeating: "a", count: 64), dns: "1.1.1.1:53",
                               directRules: "domain:ru\n10.0.0.0/8")
        let back = try XCTUnwrap(VPNConfig(providerConfiguration: config.providerConfiguration()))
        XCTAssertEqual(back.directRules, "domain:ru\n10.0.0.0/8")
        config.directRules = ""
        var legacy = config.providerConfiguration()
        legacy.removeValue(forKey: "directRules")
        XCTAssertEqual(VPNConfig(providerConfiguration: legacy)?.directRules, "",
                       "a profile saved before routing sends everything through the tunnel")
    }
}
