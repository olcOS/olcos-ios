import XCTest
@testable import olcrtc_ios

// The widgets' contract: the shared state survives the trip through the App
// Group defaults, an engaged session is claimed only while someone confirmed
// it recently, the packet tunnel keeps the names the app wrote, and the button
// says what it will do — or, when the state is unknown, offers a toggle the
// app resolves. All pure; the widget extension itself has no test target.

final class TunnelWidgetStateTests: XCTestCase {

    private let suite = "olcos.widget.tests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func sample(_ phase: TunnelWidgetState.Phase, confirmedAt: Date = Date()) -> TunnelWidgetState {
        TunnelWidgetState(phase: phase, service: "Xray", route: "REALITY · ams-1", mode: "vpn",
                          since: nil, confirmedAt: confirmedAt)
    }

    func testStateRoundTripsThroughDefaults() {
        let state = sample(.on)
        XCTAssertTrue(TunnelWidgetState.save(state, to: defaults))
        XCTAssertEqual(TunnelWidgetState.load(from: defaults), state)
    }

    func testWithoutASharedContainerNothingIsReadOrWritten() {
        XCTAssertFalse(TunnelWidgetState.save(sample(.on), to: nil))
        XCTAssertNil(TunnelWidgetState.load(from: nil))
        XCTAssertFalse(TunnelWidgetState.noteTunnel(running: true, defaults: nil))
    }

    func testAnEngagedClaimLapsesWithoutConfirmation() {
        let now = Date()
        XCTAssertTrue(sample(.on, confirmedAt: now.addingTimeInterval(-29 * 60)).isConfirmed(now: now))
        XCTAssertFalse(sample(.on, confirmedAt: now.addingTimeInterval(-31 * 60)).isConfirmed(now: now))
        // A stamp from the future is clock trouble, not proof.
        XCTAssertFalse(sample(.on, confirmedAt: now.addingTimeInterval(5 * 60)).isConfirmed(now: now))
    }

    func testSameContentIgnoresOnlyTheStamp() {
        let a = sample(.on, confirmedAt: Date())
        let b = sample(.on, confirmedAt: Date().addingTimeInterval(-600))
        XCTAssertTrue(a.sameContent(as: b))
        XCTAssertFalse(a.sameContent(as: sample(.off)))
    }

    func testThePacketTunnelKeepsTheNamesTheAppWrote() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        TunnelWidgetState.save(sample(.connecting, confirmedAt: start), to: defaults)

        XCTAssertTrue(TunnelWidgetState.noteTunnel(running: true, now: start + 5, defaults: defaults))
        var state = TunnelWidgetState.load(from: defaults)
        XCTAssertEqual(state?.phase, .on)
        XCTAssertEqual(state?.service, "Xray")
        XCTAssertEqual(state?.route, "REALITY · ams-1")
        XCTAssertEqual(state?.since, start + 5)

        // Already up: nothing worth a reload, and the start time stays.
        XCTAssertFalse(TunnelWidgetState.noteTunnel(running: true, now: start + 60, defaults: defaults))
        XCTAssertEqual(TunnelWidgetState.load(from: defaults)?.since, start + 5)

        XCTAssertTrue(TunnelWidgetState.noteTunnel(running: false, now: start + 90, defaults: defaults))
        state = TunnelWidgetState.load(from: defaults)
        XCTAssertEqual(state?.phase, .off)
        XCTAssertNil(state?.since)
    }

    func testConfirmTouchesOnlyAnEngagedState() {
        let old = Date(timeIntervalSinceReferenceDate: 2_000_000)
        TunnelWidgetState.save(sample(.off, confirmedAt: old), to: defaults)
        TunnelWidgetState.confirm(now: old + 600, defaults: defaults)
        XCTAssertEqual(TunnelWidgetState.load(from: defaults)?.confirmedAt, old)

        TunnelWidgetState.save(sample(.on, confirmedAt: old), to: defaults)
        TunnelWidgetState.confirm(now: old + 600, defaults: defaults)
        XCTAssertEqual(TunnelWidgetState.load(from: defaults)?.confirmedAt, old + 600)
    }

    func testTunnelStatesMapToWidgetPhases() {
        let phase = TunnelWidgetPublisher.phase(for:recovering:)
        XCTAssertEqual(phase(.disconnected, false), .off)
        XCTAssertEqual(phase(.connecting, false), .connecting)
        XCTAssertEqual(phase(.connected, false), .on)
        XCTAssertEqual(phase(.waitingForNetwork, false), .waiting)
        XCTAssertEqual(phase(.failed("no peer"), false), .failed)
        // A failure the manager is still recovering from is not a verdict.
        XCTAssertEqual(phase(.failed("no peer"), true), .connecting)
    }
}

@MainActor
final class TunnelWidgetDisplayTests: XCTestCase {

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

    private func state(_ phase: TunnelWidgetState.Phase, confirmedAt: Date = Date(),
                       named: Bool = true, since: Date? = nil) -> TunnelWidgetState {
        TunnelWidgetState(phase: phase,
                          service: named ? "Xray" : nil,
                          route: named ? "REALITY · ams-1" : nil,
                          mode: "vpn", since: since, confirmedAt: confirmedAt)
    }

    func testUnknownStateOffersAToggle() {
        let model = TunnelWidgetDisplay.model(for: nil, now: Date())
        XCTAssertEqual(model.tone, .unknown)
        XCTAssertEqual(model.headline, TunnelWidgetDisplay.brand)
        XCTAssertEqual(model.action, .toggle)
    }

    func testAConfirmedSessionOffersTurningOff() {
        let since = Date().addingTimeInterval(-3_600)
        let model = TunnelWidgetDisplay.model(for: state(.on, since: since), now: Date())
        XCTAssertEqual(model.tone, .on)
        XCTAssertEqual(model.headline, L10n.stateConnected.localized())
        XCTAssertEqual(model.detail, "Xray · REALITY · ams-1")
        XCTAssertEqual(model.action, .turnOff)
        XCTAssertEqual(model.since, since)
        XCTAssertEqual(model.mode, L10n.tunnelModeVPN.localized())
    }

    func testAnUnconfirmedSessionIsNotCalledOn() {
        let now = Date()
        let model = TunnelWidgetDisplay.model(for: state(.on, confirmedAt: now.addingTimeInterval(-7_200)), now: now)
        XCTAssertEqual(model.tone, .unknown)
        XCTAssertEqual(model.headline, L10n.widgetStateUnknown.localized())
        XCTAssertEqual(model.action, .toggle)
        XCTAssertNil(model.since)
    }

    func testOffAndFailedOfferTurningOn() {
        let off = TunnelWidgetDisplay.model(for: state(.off), now: Date())
        XCTAssertEqual(off.tone, .off)
        XCTAssertEqual(off.action, .turnOn)
        let failed = TunnelWidgetDisplay.model(for: state(.failed), now: Date())
        XCTAssertEqual(failed.tone, .problem)
        XCTAssertEqual(failed.action, .turnOn)
        // An off state stays true however old it is.
        let oldOff = TunnelWidgetDisplay.model(for: state(.off, confirmedAt: .distantPast), now: Date())
        XCTAssertEqual(oldOff.tone, .off)
    }

    func testOffWithoutAConnectionSaysWhatIsMissing() {
        let model = TunnelWidgetDisplay.model(for: state(.off, named: false), now: Date())
        XCTAssertEqual(model.detail, L10n.widgetHintNoConnection.localized())
    }

    func testInFlightStatesOfferTurningOff() {
        XCTAssertEqual(TunnelWidgetDisplay.model(for: state(.connecting), now: Date()).action, .turnOff)
        XCTAssertEqual(TunnelWidgetDisplay.model(for: state(.waiting), now: Date()).tone, .busy)
    }

    func testButtonWordsDifferPerAction() {
        let words = Set([TunnelWidgetDisplay.Action.turnOn, .turnOff, .toggle].map(TunnelWidgetDisplay.title(for:)))
        XCTAssertEqual(words.count, 3)
    }
}
