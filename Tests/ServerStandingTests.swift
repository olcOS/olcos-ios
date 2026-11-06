import XCTest
@testable import olcrtc_ios

// One truth for "does it work": the server card's headline, the rows under it
// and the whole-server connection all read the same evidence through the same
// rules. Everything here is a pure function or a pure reducer; the views that
// draw the result (ServerCardView, ProtocolRowView, ConnectionListRow) are
// visual.
//
// What each group pins:
//   • `ProtocolStanding` — verified and recently-verified are working, a
//     failed check is failed, everything else is simply unchecked.
//   • `ProtocolsTally` + `HostHeadline.reduce` — the card says «Working» when
//     anything works, «Not working» only when every checked protocol failed,
//     and names the ones that failed instead of averaging them in.
//   • `carryingLiveTunnel` — the connection the live tunnel runs through is
//     never shown as failed or unchecked.
//   • `HealthCoordinator.bundleDisplay` / `ServerBundle.rooms` — the
//     whole-server row stands on the rooms it joins.
final class ServerStandingTests: XCTestCase {

    private var savedLanguage = "en"
    private let key = String(repeating: "ab", count: 32)

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    private let verified = HealthDisplay.verified(ms: 40, age: 20)
    private let faded = HealthDisplay.fading(ms: 40, age: 900)
    private let failed = HealthDisplay.broken(.keyMismatch, age: 60)

    private func mark(_ name: String, _ display: HealthDisplay) -> ProtocolMark {
        ProtocolMark(name: name, display: display)
    }

    private func headline(_ marks: [ProtocolMark], rows: Int? = nil, carriedLive: Bool = false,
                          summary: HealthDisplay) -> HostHeadline {
        HostHeadline.reduce(display: .base(.running), reachable: true, lastProbeAge: 5, health: summary,
                            tally: ProtocolsTally.make(marks, rows: rows ?? marks.count,
                                                       carriedLive: carriedLive))
    }

    // MARK: Standing

    func testStandingFollowsTheFadeRules() {
        XCTAssertEqual(verified.standing, .working)
        XCTAssertEqual(faded.standing, .working, "a good check inside 30 minutes still counts")
        XCTAssertEqual(failed.standing, .failed)
        XCTAssertEqual(HealthDisplay.handshakeOnly(age: 30).standing, .failed)
        XCTAssertEqual(HealthDisplay.never.standing, .unchecked)
        XCTAssertEqual(HealthDisplay.checking.standing, .unchecked)
        XCTAssertEqual(HealthDisplay.inconclusive(.networkDown, age: 5).standing, .unchecked,
                       "could not check is not a failure")
        XCTAssertEqual(HealthDisplay.stale(age: 4000).standing, .unchecked,
                       "a result too old to rely on is neither working nor failed")
    }

    func testStandingWordsAreTheOnesTheRowsAlreadyUse() {
        XCTAssertEqual(ProtocolStanding.working.title, L10n.healthVerified.localized())
        XCTAssertEqual(ProtocolStanding.failed.title, L10n.listWordNotWorking.localized())
        XCTAssertEqual(ProtocolStanding.unchecked.title, L10n.healthChipNotChecked.localized())
        XCTAssertEqual(ProtocolStanding.working.tone, .ok)
        XCTAssertEqual(ProtocolStanding.failed.tone, .error)
        XCTAssertEqual(ProtocolStanding.unchecked.tone, .unknown)
    }

    // MARK: The headline answers "can I use this server now?"

    func testFiveVerifiedAndOneFailedIsWorkingWithTheFailureNamed() {
        let marks = [mark("VK Calls", verified), mark("Jitsi", verified), mark("SaluteJazz", verified),
                     mark("MTS Link", verified), mark("Xray", verified), mark("Telemost", failed)]
        let h = headline(marks, summary: verified)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(5, 6))
        XCTAssertEqual(h.problemLine, L10n.protocolsNotResponding_fmt.formatted("Telemost"))
    }

    func testVerifiedNeverCheckedAndFadedIsWorkingWithNoFailureLine() {
        let marks = [mark("VK Calls", verified), mark("Jitsi", .never), mark("SaluteJazz", faded),
                     mark("MTS Link", .stale(age: 4000)), mark("Telemost", .inconclusive(.networkDown, age: 5))]
        let h = headline(marks, summary: verified)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(2, 5))
        XCTAssertNil(h.problemLine, "unchecked and faded protocols are not failures")
    }

    func testOnlyFadedEvidenceStillReadsWorking() {
        let h = headline([mark("VK Calls", faded), mark("Jitsi", .never)], summary: faded)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok)
    }

    func testEveryCheckedProtocolFailingIsNotWorking() {
        let marks = [mark("Telemost", failed), mark("Jitsi", .handshakeOnly(age: 30)), mark("VK Calls", .never)]
        let h = headline(marks, summary: failed)
        XCTAssertEqual(h.title, L10n.listWordNotWorking.localized())
        XCTAssertEqual(h.tone, .error)
        XCTAssertEqual(h.problemLine, L10n.protocolsNotResponding_fmt.formatted("Telemost, Jitsi"))
    }

    func testNothingCheckedIsNotChecked() {
        let h = headline([mark("VK Calls", .never), mark("Jitsi", .stale(age: 5000))], summary: .never)
        XCTAssertEqual(h.title, L10n.healthChipNotChecked.localized())
        XCTAssertEqual(h.tone, .unknown)
        XCTAssertNil(h.problemLine)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(0, 2))
    }

    func testAProtocolBeingMeasuredForTheFirstTimeDoesNotHideTheOthers() {
        let h = headline([mark("VK Calls", verified), mark("Jitsi", .checking)], summary: .checking)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok)
        let waiting = headline([mark("Jitsi", .checking)], summary: .checking)
        XCTAssertEqual(waiting.title, HealthDisplay.checking.title)
        XCTAssertEqual(waiting.tone, .progress)
    }

    func testTheRowsTheCardDrawsSetTheDenominator() {
        let h = headline([mark("VK Calls", verified)], rows: 3, summary: verified)
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(1, 3))
    }

    // MARK: Naming what failed

    func testTheFailureLineNamesTwoAndCountsTheRest() {
        XCTAssertNil(ProtocolsTally.problemLine([]))
        XCTAssertEqual(ProtocolsTally.problemLine(["Telemost"]),
                       L10n.protocolsNotResponding_fmt.formatted("Telemost"))
        XCTAssertEqual(ProtocolsTally.problemLine(["Telemost", "Jitsi"]),
                       L10n.protocolsNotResponding_fmt.formatted("Telemost, Jitsi"))
        XCTAssertEqual(ProtocolsTally.problemLine(["Telemost", "Jitsi", "VK Calls", "MTS Link"]),
                       L10n.protocolsNotResponding_fmt.formatted("Telemost, Jitsi +2"))
    }

    func testAProtocolIsNamedOnceHoweverManyOfItsRoomsFailed() {
        let tally = ProtocolsTally.make([mark("Jitsi", failed), mark("Jitsi", failed), mark("VK Calls", verified)],
                                        rows: 3)
        XCTAssertEqual(tally.failed, ["Jitsi"])
        XCTAssertEqual(tally.working, 1)
    }

    // MARK: The live tunnel

    func testTheProtocolCarryingTheLiveTunnelCountsAsWorking() {
        let stored = NodeHealth(kind: .broken, reason: .keyMismatch, source: "probe")
        let now = Date()
        let shown = HealthCoordinator.settledDisplay(for: stored, checking: false, live: true, now: now)
        XCTAssertTrue(shown.isVerified)
        XCTAssertEqual(HealthCoordinator.settledDisplay(for: stored, checking: false, live: false, now: now).standing,
                       .failed, "the same record is failed when nothing runs through it")
        let h = headline([mark("Telemost", shown)], summary: shown)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertNil(h.problemLine)
    }

    func testTheLiveTunnelOverridesEveryOlderVerdict() {
        for old in [HealthDisplay.never, .checking, .stale(age: 4000), .inconclusive(.vpnActive, age: 3),
                    .handshakeOnly(age: 60), failed] {
            XCTAssertTrue(old.carryingLiveTunnel().isVerified, "\(old)")
        }
        XCTAssertEqual(verified.carryingLiveTunnel(), verified)
        XCTAssertEqual(faded.carryingLiveTunnel(), .verified(ms: 40, age: 0), "a measured round trip is kept")
    }

    func testAWholeServerConnectionCarriedLiveIsUsableWithoutAnyProtocolVerified() {
        let h = headline([mark("Telemost", failed), mark("Jitsi", .never)], carriedLive: true, summary: verified)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.tone, .ok)
        XCTAssertEqual(h.subtitle, L10n.stateConnected.localized())
        XCTAssertEqual(h.problemLine, L10n.protocolsNotResponding_fmt.formatted("Telemost"),
                       "the room that does not answer is still named")
    }

    func testAStoppedPrimaryDoesNotOverrideWorkingSiblings() {
        let tally = ProtocolsTally.make([mark("Jitsi", faded)], rows: 1)
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true, lastProbeAge: 5,
                                    health: faded, tally: tally)
        guard case .health = h else { return XCTFail("expected health, got \(h)") }
        let none = HostHeadline.reduce(display: .base(.stopped), reachable: true, lastProbeAge: 5,
                                       health: .never, tally: ProtocolsTally.make([mark("Jitsi", .never)], rows: 1))
        XCTAssertEqual(none, .containerStopped(age: 5))
    }

    // MARK: The whole-server connection

    private func proto(_ carrier: String, _ transport: String, _ room: String) -> OlcrtcConnection {
        OlcrtcConnection(carrier: carrier, transport: transport, roomID: room, key: key, clientID: "default")
    }

    func testTheBundleStandsOnTheRoomsItJoins() throws {
        let telemost = ConnectionRecord(name: "ams · telemost", details: .olcrtc(proto("telemost", "datachannel", "1")))
        let vk = ConnectionRecord(name: "ams · vk", details: .olcrtc(proto("vkcalls", "vp8channel", "v")))
        var otherKey = proto("jitsi", "datachannel", "j")
        otherKey.key = String(repeating: "cd", count: 32)
        let elsewhere = ConnectionRecord(name: "fra", details: .olcrtc(otherKey))
        let params = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1"), proto("vkcalls", "vp8channel", "v")], bond: nil))
        let bundle = ConnectionRecord(name: "ams", details: .olcrtc(params))
        let rooms = ServerBundle.rooms(of: bundle, in: [telemost, vk, elsewhere, bundle])
        XCTAssertEqual(Set(rooms.map(\.id)), [telemost.id, vk.id])
        XCTAssertTrue(ServerBundle.rooms(of: telemost, in: [telemost, vk, bundle]).isEmpty,
                      "a single protocol joins nothing")
    }

    func testTheBundleRowStaysGreenWhileOneRoomIsDead() {
        // Its own check reached the first room, which is the dead one.
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: failed, rooms: [failed, verified]), verified)
        // Carrying the live tunnel, its own verdict is the answer whatever the rooms say.
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: verified.carryingLiveTunnel(), rooms: [failed]),
                       verified)
    }

    func testTheBundleRowFailsOnlyWhenNothingElseSpeaksForIt() {
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: failed, rooms: [.never, .stale(age: 4000)]).standing,
                       .failed)
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: .never, rooms: []).standing, .unchecked)
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: .never, rooms: [faded]).standing, .working)
    }

    func testARoomBeingMeasuredDoesNotHideTheOthers() {
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: .checking, rooms: [.checking, faded]), faded)
        XCTAssertEqual(HealthCoordinator.bundleDisplay(own: .checking, rooms: []), .checking)
    }
}
