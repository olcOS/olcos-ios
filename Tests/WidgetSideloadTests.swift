import XCTest
@testable import olcrtc_ios

// What lets the widgets see the tunnel on a sideloaded build — the App Group a
// sideload registered, read from the provisioning profile, ours first — and
// the pure pieces of the live session's card.

@MainActor
final class WidgetSideloadTests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    /// A provisioning profile as a sideload embeds it: the plist inside a
    /// binary signature.
    private func profile(groups: [String]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "sideload",
                               "Entitlements": ["com.apple.security.application-groups": groups,
                                                "application-identifier": "ABCDE12345.io.example"]],
            format: .xml, options: 0)
        var data = Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09])
        data.append(plist)
        data.append(Data([0xA0, 0x82, 0x03, 0x10, 0x30]))
        return data
    }

    func testAProfilesGroupsAreReadFromInsideItsSignature() throws {
        let renamed = "group.io.github.hotelk52339.olcrtc-ios.ABCDE12345"
        XCTAssertEqual(TunnelWidgetState.appGroups(inProfile: try profile(groups: [renamed, "group.*"])), [renamed],
                       "a wildcard is not a group to open")
        XCTAssertEqual(TunnelWidgetState.appGroups(inProfile: Data("no plist here".utf8)), [])
    }

    func testOurGroupComesFirstAndEachOnce() {
        let ordered = TunnelWidgetState.orderedAppGroups([
            "group.other", "group.io.github.hotelk52339.olcrtc-ios.T1",
            "group.other", "group.io.github.hotelk52339.olcrtc-ios",
        ])
        XCTAssertEqual(ordered, ["group.io.github.hotelk52339.olcrtc-ios.T1",
                                 "group.io.github.hotelk52339.olcrtc-ios", "group.other"])
    }

    func testTheCardsGraphKeepsTheLastSamples() {
        var history: [Double] = []
        for i in 0..<30 { history = TunnelActivityContent.appending(Double(i), to: history) }
        XCTAssertEqual(history.count, TunnelActivityContent.historyLength)
        XCTAssertEqual(history.last, 29)
        XCTAssertEqual(TunnelActivityContent.appending(.nan, to: []), [0])
        XCTAssertEqual(TunnelActivityContent.normalized([0, 50, 100]), [0, 0.5, 1])
        XCTAssertEqual(TunnelActivityContent.normalized([0, 0]), [0, 0], "nothing moving: flat")
    }

    func testTheIslandsSpeedIsShort() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ThroughputFormat.bitsShort(562_500, locale: en), "4.5M")
        XCTAssertEqual(ThroughputFormat.bitsShort(106_250, locale: en), "850K")
        XCTAssertEqual(ThroughputFormat.bitsShort(15_000_000, locale: en), "120M")
    }
}
