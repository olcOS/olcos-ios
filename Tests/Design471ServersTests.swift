import XCTest
@testable import olcrtc_ios

// #471: the Servers-tab half of the design pass — "one claim, one age, one
// latency". Every fix below is a pure function or a pure reducer, which is the
// only kind of thing this file is allowed to hold; the view changes it protects
// (the deleted read stamp, failure banner, metrics grid, quick-action button
// and list footer) are visual and are documented at their sites.
//
// What each group pins:
//   • `HostHeadline.reduce` with a tally — the count that replaced
//     `ServerCardView.failureBanner`. The headline answers "can this server be
//     used now?"; what failed is named beside it (ServerStandingTests holds the
//     full rule).
//   • `reduce` WITHOUT a tally — the defaults, so the expectations in
//     HostDisplayTests / Review469Tests stay exactly as true as they were.
//   • the machine line — the caption that replaced `ServerMetricsGrid`, built
//     from the `shortUsage` / `shortRAM` / `shortUptime` statics
//     `VPSStatFormattingTests` pins by name.
final class Design471ServersTests: XCTestCase {

    private var savedLanguage = "en"

    override func setUp() {
        super.setUp()
        // The default language follows the simulator locale; every assertion
        // here compares against `L10n.x.localized()`, but a format string and
        // the value it is compared with must resolve in ONE language.
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: the tally IS the subtitle (#471 was: failureBanner + readStamp)

    func testEveryProtocolVerifiedReadsAsOneCountedClaim() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .verified(ms: 173, age: 120),
                                    tally: ProtocolsTally(working: 2, total: 2))
        XCTAssertEqual(h.tone, .ok)
        XCTAssertEqual(h.title, HealthDisplay.verified(ms: 173, age: 120).title)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(2, 2))
        XCTAssertNil(h.problemLine)
        // The second latency leaves with the health sentence it arrived in: the
        // card prints ONE ms value, on the protocol row's evidence chip.
        XCTAssertFalse(h.subtitle.contains("173"), h.subtitle)
    }

    func testOneDeadSiblingNamesItInsteadOfSayingPartlyWorking() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .verified(ms: 90, age: 60),
                                    tally: ProtocolsTally(working: 1, total: 2, failed: ["Telemost"]))
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok, "the server is usable; the failure is named, not averaged in")
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(1, 2))
        XCTAssertEqual(h.problemLine, L10n.protocolsNotResponding_fmt.formatted("Telemost"))
    }

    func testNothingWorkingSaysNotWorking() {
        let broken = HealthDisplay.broken(.keyMismatch, age: 300)
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: broken,
                                    tally: ProtocolsTally(working: 0, total: 2, failed: ["Telemost", "Jitsi"]))
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(0, 2))
        XCTAssertEqual(h.title, L10n.listWordNotWorking.localized())
        XCTAssertEqual(h.tone, .error)
    }

    // MARK: no ages on the card

    func testStoppedSaysWhatToDoWithoutAnAge() {
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true,
                                    lastProbeAge: 120, health: .never)
        XCTAssertEqual(h, .containerStopped(age: 120))
        XCTAssertEqual(h.tone, .warn)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineStoppedHint.localized())
    }

    func testNothingInstalledKeepsTheBaseSentenceWithoutAnAge() {
        let h = HostHeadline.reduce(display: .base(.imageReady), reachable: true,
                                    lastProbeAge: 600, health: .never)
        XCTAssertEqual(h, .noContainer(.imageReady, age: 600))
        XCTAssertEqual(h.subtitle, HostBase.imageReady.subtitle)
        XCTAssertEqual(h.title, HostBase.imageReady.title)
    }

    // MARK: the defaults keep every existing expectation true

    func testAnUncountedReduceIsExactlyWhatItAlwaysWas() {
        let verified = HealthDisplay.verified(ms: 42, age: 30)
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: verified)
        XCTAssertEqual(h, .health(verified, tally: ProtocolsTally()))
        XCTAssertEqual(h.subtitle, verified.plainLine, "no tally ⇒ the verdict's own plain line")
        XCTAssertEqual(h.title, verified.title)
        XCTAssertEqual(h.tone, .ok)
    }

    func testPrecedenceIsUntouchedByTheNewInputs() {
        // Requirement 2: "couldn't check" outranks any tally, however good.
        let h = HostHeadline.reduce(display: .base(.running), reachable: false,
                                    lastProbeAge: 900, health: .verified(ms: 10, age: 5),
                                    tally: ProtocolsTally(working: 3, total: 3))
        XCTAssertEqual(h, .unreachable(age: 900))
        XCTAssertEqual(h.tone, .unknown)
    }
}
