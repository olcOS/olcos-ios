import XCTest
@testable import olcrtc_ios

// #456: the verified-health model — the staleness rule, the debounce rule, the
// aggregation rule, the persistence contract and the raw-error → human-reason
// mapper. All of it is pure, so none of this needs a probe, a network or an
// engine.
//
// The honesty invariants these tests exist to protect:
//   • GREEN (.verified) is granted ONLY for a `.working` result younger than
//     `HealthPolicy.freshSeconds` — a success is past tense after that;
//   • anything older than `HealthPolicy.staleSeconds` is `.stale`, never a
//     present-tense claim;
//   • "couldn't check" (.inconclusive) is a SEPARATE case from "broken" and is
//     grey, not red — an unreachable VPS never reports the server as failed;
//   • a corrupt or unrecognised persisted value degrades to `.unknown`/empty, never to a
//     throw that could take a user's data with it.

@MainActor
final class HealthModelTests: XCTestCase {

    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?
    private var savedLanguage: String = ""

    override func setUp() {
        super.setUp()
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        HealthCoordinator.shared._resetForTesting()
    }

    override func tearDown() {
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: helpers

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func health(_ kind: NodeHealthKind, agoSeconds: TimeInterval,
                        rttMs: Int? = nil, reason: HealthReason? = nil) -> NodeHealth {
        NodeHealth(kind: kind,
                   checkedAt: now.addingTimeInterval(-agoSeconds),
                   rttMs: rttMs,
                   reason: reason,
                   source: "probe")
    }

    private func display(_ h: NodeHealth?, checking: Bool = false) -> HealthDisplay {
        HealthCoordinator.display(for: h, checking: checking, now: now)
    }

    // MARK: display — the staleness rule

    func testNoRecordIsNeverChecked() {
        XCTAssertEqual(display(nil), .never)
        // `.never` must NOT read as good.
        XCTAssertFalse(HealthDisplay.never.isVerified)
        XCTAssertEqual(HealthDisplay.never.tone, .unknown)
    }

    func testCheckingOverridesEverything() {
        // A re-check must never briefly show the old verdict as current.
        XCTAssertEqual(display(health(.working, agoSeconds: 10, rttMs: 42), checking: true), .checking)
        XCTAssertEqual(display(health(.broken, agoSeconds: 10, reason: .keyMismatch), checking: true), .checking)
        XCTAssertEqual(display(nil, checking: true), .checking)
        XCTAssertTrue(HealthDisplay.checking.isChecking)
    }

    func testWorkingIsGreenOnlyInsideTheFreshWindow() {
        // 10 s → GREEN.
        let fresh = display(health(.working, agoSeconds: 10, rttMs: 48))
        XCTAssertEqual(fresh, .verified(ms: 48, age: 10))
        XCTAssertTrue(fresh.isVerified)
        XCTAssertEqual(fresh.tone, .ok)

        // 10 min → the SAME success, now past tense: neutral, never green.
        let aging = display(health(.working, agoSeconds: 600, rttMs: 48))
        XCTAssertEqual(aging, .fading(ms: 48, age: 600))
        XCTAssertFalse(aging.isVerified)
        XCTAssertEqual(aging.tone, .unknown)

        // 2 h → too old to trust at all.
        let old = display(health(.working, agoSeconds: 7200, rttMs: 48))
        XCTAssertEqual(old, .stale(age: 7200))
        XCTAssertFalse(old.isVerified)
        XCTAssertEqual(old.tone, .unknown)
    }

    func testFreshnessBoundariesAreExact() {
        // One second inside the window is still green; exactly at it is not.
        XCTAssertTrue(display(health(.working, agoSeconds: HealthPolicy.freshSeconds - 1)).isVerified)
        XCTAssertFalse(display(health(.working, agoSeconds: HealthPolicy.freshSeconds)).isVerified)
        // Exactly at staleSeconds is already stale.
        XCTAssertEqual(display(health(.working, agoSeconds: HealthPolicy.staleSeconds)),
                       .stale(age: HealthPolicy.staleSeconds))
    }

    func testHandshakeIsAmberNeverGreen() {
        // The user's telemost passed exactly this stage while moving zero bytes.
        XCTAssertEqual(display(health(.handshake, agoSeconds: 10)), .handshakeOnly(age: 10))
        XCTAssertEqual(display(health(.handshake, agoSeconds: 600)), .handshakeOnly(age: 600))
        XCTAssertEqual(display(health(.handshake, agoSeconds: 7200)), .stale(age: 7200))
        XCTAssertEqual(HealthDisplay.handshakeOnly(age: 10).tone, .warn)
        XCTAssertFalse(HealthDisplay.handshakeOnly(age: 10).isVerified)
    }

    func testBrokenIsRedAndCarriesItsReason() {
        let d = display(health(.broken, agoSeconds: 10, reason: .keyMismatch))
        XCTAssertEqual(d, .broken(.keyMismatch, age: 10))
        XCTAssertEqual(d.tone, .error)
        XCTAssertEqual(d.title, L10n.healthReasonKeyMismatchShort.localized())
        XCTAssertEqual(d.suggestedAction, .recoverConnection)
        XCTAssertEqual(display(health(.broken, agoSeconds: 600, reason: .keyMismatch)),
                       .broken(.keyMismatch, age: 600))
        XCTAssertEqual(display(health(.broken, agoSeconds: 7200, reason: .keyMismatch)),
                       .stale(age: 7200))
    }

    func testInconclusiveIsGreyNotRed() {
        // Requirement 2: "couldn't check" is NEVER a failure verdict.
        let d = display(health(.inconclusive, agoSeconds: 10, reason: .hostUnreachable))
        XCTAssertEqual(d, .inconclusive(.hostUnreachable, age: 10))
        XCTAssertEqual(d.tone, .unknown)
        XCTAssertNotEqual(d.tone, .error)
        XCTAssertEqual(d.title, L10n.healthInconclusive.localized())
        XCTAssertEqual(display(health(.inconclusive, agoSeconds: 600, reason: .networkDown)),
                       .inconclusive(.networkDown, age: 600))
        XCTAssertEqual(display(health(.inconclusive, agoSeconds: 7200, reason: .networkDown)),
                       .stale(age: 7200))
    }

    func testUnknownKindDegradesToStaleAtEveryAge() {
        // A value written by a future build must never render as good.
        for age in [10.0, 600.0, 7200.0] {
            XCTAssertEqual(display(health(.unknown, agoSeconds: age)), .stale(age: age))
        }
    }

    func testFutureTimestampDoesNotProduceNegativeAge() {
        // Clock skew must not make the age go negative (it would read as fresh).
        let d = display(health(.working, agoSeconds: -500, rttMs: 5))
        XCTAssertEqual(d, .verified(ms: 5, age: 0))
    }

    // MARK: shouldProbe — the debounce rule

    func testShouldProbeNeverCheckedIsAlwaysTrue() {
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: nil, force: false, now: now))
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: nil, force: true, now: now))
    }

    func testShouldProbeDebouncesRecentResults() {
        let recent = health(.working, agoSeconds: 30, rttMs: 20)
        XCTAssertFalse(HealthCoordinator.shouldProbe(existing: recent, force: false, now: now))
        // A user-initiated check always wins over the debounce.
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: recent, force: true, now: now))
    }

    func testShouldProbeAllowsAfterTheRecheckWindow() {
        let old = health(.working, agoSeconds: 300, rttMs: 20)   // 5 min > 2 min debounce
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: old, force: false, now: now))
        // Exactly at the boundary is allowed (>=).
        let atBoundary = health(.working, agoSeconds: HealthPolicy.minRecheckSeconds)
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: atBoundary, force: false, now: now))
    }

    /// A probe costs a Jitsi room about a minute of rejoining after it leaves,
    /// so automatic re-probes of one wait much longer; the user's own check does not.
    func testShouldProbeWaitsLongerForAJitsiRoom() {
        let fiveMinutes = health(.working, agoSeconds: 300, rttMs: 20)
        XCTAssertFalse(HealthCoordinator.shouldProbe(existing: fiveMinutes, force: false, now: now, carrier: "jitsi"))
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: fiveMinutes, force: true, now: now, carrier: "jitsi"))
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: fiveMinutes, force: false, now: now, carrier: "salutejazz"))
        let quarter = health(.working, agoSeconds: HealthPolicy.jitsiRecheckSeconds)
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: quarter, force: false, now: now, carrier: "jitsi"))
    }

    // MARK: summarize — best evidence wins, "couldn't check" never masks broken

    func testSummarizePrecedence() {
        let checking  = HealthDisplay.checking
        let verified  = HealthDisplay.verified(ms: 10, age: 1)
        let fading    = HealthDisplay.fading(ms: 10, age: 600)
        let handshake = HealthDisplay.handshakeOnly(age: 1)
        let broken    = HealthDisplay.broken(.noPeer, age: 1)
        let inconc    = HealthDisplay.inconclusive(.hostUnreachable, age: 1)
        let stale     = HealthDisplay.stale(age: 7200)
        let never     = HealthDisplay.never

        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc, broken, handshake, fading, verified, checking]),
                       checking)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc, broken, handshake, fading, verified]),
                       verified)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc, broken, handshake, fading]), fading)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc, broken, handshake]), handshake)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc, broken]), broken)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale, inconc]), inconc)
        XCTAssertEqual(HealthCoordinator.summarize([never, stale]), stale)
        XCTAssertEqual(HealthCoordinator.summarize([never]), never)
    }

    func testSummarizeOfNothingIsNeverNotGreen() {
        XCTAssertEqual(HealthCoordinator.summarize([]), .never)
    }

    // MARK: persistence

    func testNodeHealthCodableRoundTrip() throws {
        let original = NodeHealth(kind: .broken,
                                  checkedAt: Date(timeIntervalSinceReferenceDate: 12345),
                                  rttMs: nil,
                                  reason: .keyMismatch,
                                  detail: "handshake client: read welcome: EOF",
                                  source: "probe")
        let data = try JSONEncoder().encode(["a": original])
        let back = try JSONDecoder().decode([String: NodeHealth].self, from: data)
        XCTAssertEqual(back["a"], original)
        XCTAssertEqual(back["a"]?.resolvedKind, .broken)
        XCTAssertEqual(back["a"]?.resolvedReason, .keyMismatch)
    }

    func testDetailIsCappedAt200Characters() {
        let h = NodeHealth(kind: .broken, detail: String(repeating: "x", count: 500), source: "probe")
        XCTAssertEqual(h.detail?.count, 200)
    }

    func testUnrecognisedKindDecodesToUnknownAndNeverThrows() throws {
        // A raw String (not a Codable enum) is exactly why this can't throw.
        let json = Data(#"{"a":{"kind":"martian","checkedAt":0,"source":"probe"}}"#.utf8)
        let map = try JSONDecoder().decode([String: NodeHealth].self, from: json)
        XCTAssertEqual(map["a"]?.resolvedKind, .unknown)
        XCTAssertEqual(map["a"]?.resolvedReason, .unknown)   // absent reason → .unknown
    }

    func testCorruptStoreDecodesToAnEmptyMap() {
        // Requirement: a decode failure here can NEVER harm olcrtc_records_v2.
        XCTAssertTrue(HealthCoordinator.decodeStore(Data("not json at all".utf8), now: now).isEmpty)
        XCTAssertTrue(HealthCoordinator.decodeStore(Data(), now: now).isEmpty)
        XCTAssertTrue(HealthCoordinator.decodeStore(nil, now: now).isEmpty)
    }

    func testDecodeStoreDropsEntriesPastTheForgetWindow() throws {
        let keep = NodeHealth(kind: .working, checkedAt: now.addingTimeInterval(-60), source: "probe")
        let drop = NodeHealth(kind: .working,
                              checkedAt: now.addingTimeInterval(-HealthPolicy.forgetSeconds - 60),
                              source: "probe")
        let data = try JSONEncoder().encode(["keep": keep, "drop": drop])
        let map = HealthCoordinator.decodeStore(data, now: now)
        XCTAssertEqual(Array(map.keys), ["keep"])
    }

    func testCoordinatorPersistsAndReloadsAVerdict() {
        let id = UUID()
        XCTAssertEqual(HealthCoordinator.shared.display(for: id, now: now), .never)
        HealthCoordinator.shared.noteLiveVerified(recordID: id, rttMs: 31)
        let d = HealthCoordinator.shared.display(for: id)
        XCTAssertTrue(d.isVerified)
        XCTAssertEqual(HealthCoordinator.shared.health(for: id)?.rttMs, 31)
        XCTAssertEqual(HealthCoordinator.shared.health(for: id)?.source, "live")
        // boc #470: the "persists" half of the name. #470 was: only the in-memory
        // map above was read back, so a no-op `save()` (or a broken encoder)
        // passed. `save()` writes through a serial queue — drain it, then decode
        // the bytes UserDefaults actually holds, the way `load()` does on launch.
        HealthCoordinator.flushPendingWrites()
        let reloaded = HealthCoordinator.decodeStore(UserDefaults.standard.data(forKey: healthKey),
                                                     now: Date())
        XCTAssertEqual(reloaded[id.uuidString]?.rttMs, 31, "the verdict must survive a relaunch")
        XCTAssertEqual(reloaded[id.uuidString]?.resolvedKind, .working)
        XCTAssertEqual(reloaded[id.uuidString]?.source, "live")
        // eoc #470

        // A "couldn't check" reason is stored as .inconclusive, never as .broken.
        HealthCoordinator.shared.noteFailure(recordID: id, raw: "no such host", source: "probe")
        XCTAssertEqual(HealthCoordinator.shared.health(for: id)?.resolvedKind, .inconclusive)
        // A node-specific reason is stored as .broken.
        HealthCoordinator.shared.noteFailure(recordID: id,
                                             raw: "handshake client: read welcome: EOF",
                                             source: "probe")
        XCTAssertEqual(HealthCoordinator.shared.health(for: id)?.resolvedKind, .broken)
        XCTAssertEqual(HealthCoordinator.shared.health(for: id)?.resolvedReason, .keyMismatch)
    }

    func testCoordinatorSummaryAggregatesNodes() {
        let good = UUID(), bad = UUID(), never = UUID()
        HealthCoordinator.shared.noteLiveVerified(recordID: good, rttMs: 12)
        HealthCoordinator.shared.noteFailure(recordID: bad, raw: "no peer", source: "probe")
        // Best evidence wins for the host headline.
        XCTAssertTrue(HealthCoordinator.shared.summary(for: [never, bad, good]).isVerified)
        // Without the verified node, "broken" outranks "never checked".
        guard case .broken(let reason, _) = HealthCoordinator.shared.summary(for: [never, bad]) else {
            return XCTFail("a broken node must outrank a never-checked one")
        }
        XCTAssertEqual(reason, .noPeer)
    }

    // MARK: HealthFailureMapper — raw engine text → a human reason

    func testMapperKeyMismatchIsTheUsersIncident() {
        // The user reinstalled the server, its key rotated, and the app dumped
        // this at them. It must resolve to a sentence + a Recover action.
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "run public client: handshake client: read welcome: EOF"),
                       .keyMismatch)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "handshake rejected"), .keyMismatch)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "record authentication failed"), .keyMismatch)
        XCTAssertEqual(HealthReason.keyMismatch.action, .recoverConnection)
        XCTAssertFalse(HealthReason.keyMismatch.message.isEmpty)
    }

    func testMapperHandshakeTimeoutIsNoAnswerNotKeyMismatch() {
        // A shared connection on a second phone: the hello went out, nobody
        // answered within the handshake deadline. The server log showed no
        // session from that phone, so "key no longer matches" was a false claim.
        for raw in ["handshake client: read welcome: i/o timeout",
                    "run public client: handshake client: context deadline exceeded",
                    "handshake client: read welcome: read hdr: timeout"] {
            XCTAssertEqual(HealthFailureMapper.reason(forRaw: raw), .noPeer, raw)
        }
        // A real decrypt failure still resolves to the key.
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "handshake client: read welcome: EOF"), .keyMismatch)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "handshake challenge mismatch"), .keyMismatch)
    }

    func testMapperOrderIsFirstMatchWins() {
        // "readiness timed out" must be .noPeer, NOT the generic .timedOut.
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "olcRTC runtime readiness timed out"), .noPeer)
        // "network is unreachable" must be .networkDown, NOT .hostUnreachable.
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "dial tcp: network is unreachable"), .networkDown)
    }

    func testMapperCoversTheRestOfTheTable() {
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "jitsi: invalid room URL"), .roomInvalid)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "telemost api: 403"), .carrierRejected)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "no such host"), .networkDown)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "address already in use"), .portBusy)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "dial tcp 10.0.0.1:22: connection refused"),
                       .hostUnreachable)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "context deadline exceeded"), .timedOut)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: ""), .unknown)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "something nobody has ever seen"), .unknown)
    }

    func testMapperTellsADeadResolverFromATimeout() {
        // A second phone on a network that does not reach the configured
        // resolver: every lookup dies at "<resolver>:53", the row read
        // "Timed out" and pointed at the server. Switching the resolver fixed
        // it, so the resolver — not the server — is the diagnosis.
        for raw in ["lookup telemost.yandex.ru on 77.88.8.8:53: read udp 10.0.0.2:51234->77.88.8.8:53: i/o timeout",
                    "telemost api: guest register: Post \"https://telemost.yandex.ru/api\": dial tcp: lookup telemost.yandex.ru on 77.88.8.8:53: read udp 10.0.0.2:51234->77.88.8.8:53: i/o timeout",
                    "dial tcp: lookup meet.example.org on 1.1.1.1:53: dial udp 1.1.1.1:53: connect: network is unreachable",
                    "lookup stun.l.google.com on 8.8.8.8:53: server misbehaving",
                    "lookup api.example on 77.88.8.8:53: read udp 10.0.0.2:5000->77.88.8.8:53: read: connection refused"] {
            XCTAssertEqual(HealthFailureMapper.reason(forRaw: raw), .dnsUnreachable, raw)
        }
        // A resolver that ANSWERED "no such host" is still the phone's network,
        // and a plain timeout with no lookup in it is still a timeout.
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "lookup nope.example on 1.1.1.1:53: no such host"), .networkDown)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "dial tcp 1.2.3.4:443: i/o timeout"), .timedOut)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "handshake client: read welcome: i/o timeout"), .noPeer)
        // The fix lives in Settings → DNS, and the verdict is "couldn't check".
        XCTAssertEqual(HealthReason.dnsUnreachable.action, .openDNSSettings)
        XCTAssertEqual(ConnectActionSite.site(for: .openDNSSettings), .settings)
        XCTAssertFalse(HealthReason.dnsUnreachable.headline.isEmpty)
        XCTAssertFalse(HealthReason.dnsUnreachable.message.isEmpty)
        XCTAssertNotEqual(HealthReason.dnsUnreachable.headline, HealthReason.timedOut.headline)
    }

    func testDefaultResolverIsCloudflareAndIsAPreset() {
        XCTAssertEqual(SettingsStore.Defaults.dnsServer, "1.1.1.1:53")
        XCTAssertTrue(AppConstants.dnsPresets.contains { $0.value == SettingsStore.Defaults.dnsServer },
                      "the default must be pickable, or the picker shows a raw value on a fresh install")
        XCTAssertEqual(AppConstants.dnsPresets.first?.value, SettingsStore.Defaults.dnsServer,
                       "the default preset leads the picker")
    }

    func testMapperIsCaseInsensitive() {
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "READ WELCOME: EOF"), .keyMismatch)
    }

    func testSSHMapperClassifiesAuthAndReachability() {
        XCTAssertEqual(HealthFailureMapper.reason(forSSH: "permission denied"), .sshAuth)
        XCTAssertEqual(HealthFailureMapper.reason(forSSH: "All authentication methods failed"), .sshAuth)
        XCTAssertEqual(HealthFailureMapper.reason(forSSH: "connection refused"), .hostUnreachable)
        XCTAssertEqual(HealthFailureMapper.reason(forSSH: "i/o timed out"), .hostUnreachable)
        // Anything else falls through to the engine table.
        XCTAssertEqual(HealthFailureMapper.reason(forSSH: "context deadline exceeded"), .timedOut)
    }

    func testIsInconclusiveSplitsCouldNotCheckFromBroken() {
        // "We could not check" — must never render as a failed server.
        for r in [HealthReason.networkDown, .hostUnreachable, .sshAuth, .portBusy, .vpnActive, .unknown,
                  .dnsUnreachable] {
            XCTAssertTrue(HealthFailureMapper.isInconclusive(r), "\(r) must be inconclusive")
        }
        // Real, node-specific failures.
        for r in [HealthReason.keyMismatch, .noPeer, .roomInvalid, .carrierRejected,
                  .containerStopped, .timedOut] {
            XCTAssertFalse(HealthFailureMapper.isInconclusive(r), "\(r) must be a real failure")
        }
    }

    func testTheCoreNamedHandshakeCauseWins() {
        // A wrong key still ends in a welcome timeout underneath; the core's
        // own classification must win over rule 0's "nobody answered".
        XCTAssertEqual(HealthFailureMapper.reason(forRaw:
            "handshake: key does not match the peer: handshake client: read welcome: i/o timeout"),
            .keyMismatch)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw:
            "handshake: peer speaks an incompatible olcrtc protocol: unexpected frame"),
            .serverOutdated)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw:
            "handshake: peer did not answer the handshake: read welcome: timeout"), .noPeer)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "handshake: no peer in room"), .noPeer)
        // An outdated server is a verdict about the node, and its fix lives on
        // the server card rather than in an inline button.
        XCTAssertFalse(HealthFailureMapper.isInconclusive(.serverOutdated))
        XCTAssertNil(HealthReason.serverOutdated.action)
    }

    func testEveryReasonHasAHeadlineAndAMessage() {
        for r in HealthReason.allCases {
            XCTAssertFalse(r.headline.isEmpty, "\(r) needs a headline")
            XCTAssertFalse(r.message.isEmpty, "\(r) needs a message")
            XCTAssertNotEqual(r.headline, r.rawValue, "\(r) headline must be localized, not the raw case")
        }
    }

    func testEveryActionHasATitle() {
        for a in [HealthAction.recoverConnection, .checkRoom, .startContainer,
                  .openPortSettings, .retry, .verify] {
            XCTAssertFalse(a.title.isEmpty, "\(a) needs a title")
        }
    }

    // MARK: HealthAge

    /// A verdict is dated with a clock time, never an age that goes stale on
    /// screen: today, yesterday, and an earlier day each read differently.
    func testHealthAgePhraseIsAClockTime() {
        SettingsStore.shared.language = "en"
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 40))!
        let today = HealthAge.phrase(3600, now: now)
        XCTAssertTrue(today.hasPrefix("at "), today)
        XCTAssertFalse(today.contains("ago"), today)
        let yesterday = HealthAge.phrase(24 * 3600, now: now)
        XCTAssertTrue(yesterday.hasPrefix("yesterday at "), yesterday)
        let earlier = HealthAge.phrase(3 * 24 * 3600, now: now)
        XCTAssertTrue(earlier.contains("October"), earlier)
        XCTAssertEqual(HealthAge.phrase(-100, now: now), HealthAge.phrase(0, now: now))   // clamped
        SettingsStore.shared.language = "ru"
        XCTAssertTrue(HealthAge.phrase(3600, now: now).hasPrefix("в "))
        XCTAssertTrue(HealthAge.phrase(24 * 3600, now: now).hasPrefix("вчера в "))
        SettingsStore.shared.language = "en"
    }

    func testHealthAgeShortIsTheTimeTodayAndTheDayBefore() {
        SettingsStore.shared.language = "en"
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 40))!
        let today = HealthAge.short(600, now: now)
        XCTAssertTrue(today.contains(":"), today)
        let before = HealthAge.short(2 * 24 * 3600, now: now)
        XCTAssertFalse(before.contains(":"), before)
        XCTAssertNotEqual(today, before)
    }

    // MARK: chip labels — the shared Connections / Manage VPS vocabulary

    func testChipLabelsNeverClaimSuccessWithoutEvidence() {
        XCTAssertEqual(HealthDisplay.never.chipLabel, L10n.healthChipNever.localized())
        XCTAssertEqual(HealthDisplay.checking.chipLabel, "")           // the chip spins instead
        XCTAssertEqual(HealthDisplay.inconclusive(.networkDown, age: 5).chipLabel,
                       L10n.healthChipUnchecked.localized())
        XCTAssertTrue(HealthDisplay.verified(ms: 48, age: 120).chipLabel.contains("48 ms"))
        // A verified chip without an RTT still shows only its age, never a number.
        // #459: the chip takes the SHORT duration ("2m"), not the phrase — the
        // value beside it supplies the grammar, so nothing may append "ago".
        XCTAssertEqual(HealthDisplay.verified(ms: nil, age: 120).chipLabel, HealthAge.short(120))
    }

    func testSuggestedActionOffersVerifyWhereNothingIsKnown() {
        XCTAssertEqual(HealthDisplay.never.suggestedAction, .verify)
        XCTAssertEqual(HealthDisplay.stale(age: 7200).suggestedAction, .verify)
        XCTAssertNil(HealthDisplay.verified(ms: 1, age: 1).suggestedAction)
        XCTAssertNil(HealthDisplay.checking.suggestedAction)
        XCTAssertEqual(HealthDisplay.broken(.roomInvalid, age: 1).suggestedAction, .checkRoom)
        XCTAssertEqual(HealthDisplay.broken(.containerStopped, age: 1).suggestedAction, .startContainer)
        XCTAssertEqual(HealthDisplay.broken(.portBusy, age: 1).suggestedAction, .openPortSettings)
        XCTAssertNil(HealthDisplay.inconclusive(.vpnActive, age: 1).suggestedAction)
    }
}
