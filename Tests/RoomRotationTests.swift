import XCTest
@testable import olcrtc_ios

// Per-protocol room auto-update.
//
// Three layers, bottom up:
//   * RoomRotationRuleTests        what each protocol offers, its default, and how a
//                                  stored value its protocol does not offer resolves
//   * RoomRotationPolicyTests      the pure decisions: which connections a rule
//                                  covers, the exceptions, due / postpone / force
//   * RoomRotationCoordinatorTests the coordinator's pass, driven through its
//                                  injected environment — no stores, Keychain,
//                                  SSH or live tunnel
//
// INTEGRATION-ONLY (not covered here, by design):
//   * The room creators' network legs (VKCallRoomService, SaluteJazzRoomService)
//     and a real `Provisioner.reconfigure` against a saved server.
//   * The silent account check's network legs (`VKCallRoomService.sessionState`,
//     `MTSLinkRoomService.sessionState`) — the verdict mapping each one makes
//     is pinned in VKCallRoomTests / MTSLinkTests.

// MARK: - The rule model

final class RoomRotationRuleTests: XCTestCase {

    private let schedule: [RoomRotationRule] = [.off, .every6Hours, .every12Hours, .daily, .every3Days, .weekly]

    func testEachProtocolOffersOnlyItsOwnChoices() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "telemost"), [.off, .automatic])
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            XCTAssertEqual(RoomRotationRule.allowed(for: carrier), schedule, carrier)
        }
    }

    func testNobodyButTelemostOffersAutomatic() {
        for carrier in ["vkcalls", "salutejazz", "jitsi", "mtslink"] {
            XCTAssertFalse(RoomRotationRule.allowed(for: carrier, mtslinkCanCreate: true).contains(.automatic), carrier)
        }
    }

    func testTheNewIntervalsAreKeptWhereTheProtocolOffersThem() {
        XCTAssertEqual(RoomRotationRule.resolved(.every6Hours, for: "vkcalls"), .every6Hours)
        XCTAssertEqual(RoomRotationRule.resolved(.every12Hours, for: "jitsi"), .every12Hours)
        XCTAssertEqual(RoomRotationRule.resolved(.every3Days, for: "salutejazz"), .every3Days)
        // Telemost keeps its own Off / Automatic.
        XCTAssertEqual(RoomRotationRule.resolved(.every6Hours, for: "telemost"), .automatic)
    }

    /// Earlier builds saved "daily" and "weekly"; those words keep their meaning.
    func testSavedDailyAndWeeklyKeepTheirMeaning() {
        XCTAssertEqual(RoomRotationRule(rawValue: "daily"), .daily)
        XCTAssertEqual(RoomRotationRule(rawValue: "weekly"), .weekly)
        XCTAssertEqual(RoomRotationRule(rawValue: "daily")?.intervalHours, 24)
        XCTAssertEqual(RoomRotationRule(rawValue: "weekly")?.intervalHours, 168)
    }

    func testAWordNoBuildWritesReadsAsOff() {
        for stored in ["monthly", "6h", "Daily", "WEEKLY", ""] {
            XCTAssertNil(RoomRotationRule(rawValue: stored), stored)
            XCTAssertEqual(RoomRotationRule.resolved(RoomRotationRule(rawValue: stored), for: "vkcalls"), .off, stored)
        }
    }

    /// MTS Link offers the same schedule as VK Calls — but only while the app
    /// can make a meeting at all (it replays the create request it watched the
    /// owner's page send). Until one is known the picker offers Off and the
    /// note under it says why.
    func testMTSLinkOffersAScheduleOnlyOnceTheAppCanMakeRooms() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "mtslink", mtslinkCanCreate: true), schedule)
        XCTAssertEqual(RoomRotationRule.allowed(for: "mtslink", mtslinkCanCreate: false), [.off])
        XCTAssertEqual(RoomRotationRule.defaultRule(for: "mtslink"), .off)
        // A schedule saved before the create request was learned resolves Off.
        XCTAssertEqual(RoomRotationRule.resolved(.daily, for: "mtslink", mtslinkCanCreate: false), .off)
        XCTAssertEqual(RoomRotationRule.resolved(.daily, for: "mtslink", mtslinkCanCreate: true), .daily)
    }

    func testWBStreamIsNoLongerAProtocolWithARule() {
        XCTAssertFalse(RoomRotationRule.carriers.contains("wbstream"))
        XCTAssertEqual(RoomRotationRule.allowed(for: "wbstream"), [.off])
    }

    func testAProtocolOutsideTheRulesCanOnlyBeOff() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "a-future-service"), [.off])
        XCTAssertEqual(RoomRotationRule.defaultRule(for: "a-future-service"), .off)
    }

    func testDefaultsAreTelemostAutomaticAndEverythingElseOff() {
        XCTAssertEqual(RoomRotationRule.defaultRule(for: "telemost"), .automatic)
        for carrier in ["vkcalls", "salutejazz", "mtslink", "jitsi"] {
            XCTAssertEqual(RoomRotationRule.defaultRule(for: carrier), .off, carrier)
        }
        XCTAssertEqual(RoomRotationRule.defaults,
                       ["telemost": .automatic, "vkcalls": .off, "salutejazz": .off,
                        "mtslink": .off, "jitsi": .off])
    }

    func testEveryDefaultIsOneOfItsProtocolsChoices() {
        for carrier in RoomRotationRule.carriers {
            XCTAssertTrue(RoomRotationRule.allowed(for: carrier)
                .contains(RoomRotationRule.defaultRule(for: carrier)), carrier)
        }
    }

    func testAStoredChoiceTheProtocolDoesNotOfferResolvesToItsDefault() {
        XCTAssertEqual(RoomRotationRule.resolved(.daily, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(.weekly, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(.automatic, for: "vkcalls"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(.automatic, for: "jitsi"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(nil, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(nil, for: "salutejazz"), .off)
        // A choice the protocol does offer passes through.
        XCTAssertEqual(RoomRotationRule.resolved(.off, for: "telemost"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(.weekly, for: "jitsi"), .weekly)
    }

    func testWBStreamIsForcedOffWhateverWasStored() {
        let stored: [RoomRotationRule?] = [nil] + RoomRotationRule.allCases.map { Optional($0) }
        for value in stored {
            XCTAssertEqual(RoomRotationRule.resolved(value, for: "wbstream"), .off)
        }
    }

    func testNormalizedHoldsExactlyTheFiveProtocols() {
        let rules = RoomRotationRule.normalized([
            "telemost": .daily,            // not offered: its default
            "vkcalls": .weekly,
            "jitsi": .daily,
            "wbstream": .weekly,           // no longer offered: dropped
            "a-future-service": .daily,    // not a protocol with a rule: dropped
        ], mtslinkCanCreate: false)
        XCTAssertEqual(rules, ["telemost": .automatic, "vkcalls": .weekly, "salutejazz": .off,
                               "mtslink": .off, "jitsi": .daily])
    }

    func testOnlyTheScheduledRulesHaveHours() {
        XCTAssertEqual(RoomRotationRule.every6Hours.intervalHours, 6)
        XCTAssertEqual(RoomRotationRule.every12Hours.intervalHours, 12)
        XCTAssertEqual(RoomRotationRule.daily.intervalHours, 24)
        XCTAssertEqual(RoomRotationRule.every3Days.intervalHours, 72)
        XCTAssertEqual(RoomRotationRule.weekly.intervalHours, 168)
        XCTAssertNil(RoomRotationRule.off.intervalHours)
        XCTAssertNil(RoomRotationRule.automatic.intervalHours)
    }

    func testOnlyOffMakesTheAppDoNothing() {
        XCTAssertFalse(RoomRotationRule.off.isOn)
        for rule in RoomRotationRule.allCases where rule != .off {
            XCTAssertTrue(rule.isOn, rule.rawValue)
        }
    }

    /// The raw values are what UserDefaults holds, so they are a contract.
    func testThePersistedWordsAreStable() {
        XCTAssertEqual(RoomRotationRule.allCases.map(\.rawValue),
                       ["off", "automatic", "every6h", "every12h", "daily", "every3d", "weekly"])
    }

    // MARK: The window

    func testAWindowIsStoredAndReadBackAsItWasWritten() {
        for window in [RoomRotationWindow.anyTime, .night, .hour(0), .hour(3), .hour(23)] {
            XCTAssertEqual(RoomRotationWindow(stored: window.stored), window, window.stored)
        }
        XCTAssertEqual(RoomRotationWindow.hour(3).stored, "hour:3")
        XCTAssertEqual(RoomRotationWindow.night.stored, "night")
        XCTAssertEqual(RoomRotationWindow.anyTime.stored, "anytime")
    }

    /// What an earlier build saved has no window: the rule keeps meaning what it meant.
    func testNoWindowOrAnUnknownOneReadsAsAnyTime() {
        for stored in [nil, "", "evening", "hour:", "hour:24", "hour:-1", "hour:x", "NIGHT"] as [String?] {
            XCTAssertEqual(RoomRotationWindow(stored: stored), .anyTime, stored ?? "nil")
        }
    }

    func testAChosenHourStaysInsideTheDay() {
        XCTAssertEqual(RoomRotationWindow.clampedHour(-5), .hour(0))
        XCTAssertEqual(RoomRotationWindow.clampedHour(40), .hour(23))
        XCTAssertEqual(RoomRotationWindow.clampedHour(7), .hour(7))
    }

    func testAWindowThatIsNotSavedReadsAsAnyTime() {
        let windows = RoomRotationWindow.normalized(["vkcalls": .night, "wbstream": .hour(4)])
        XCTAssertEqual(windows["vkcalls"], .night)
        XCTAssertEqual(windows["jitsi"], .anyTime)
        XCTAssertNil(windows["wbstream"], "only the protocols with a rule keep a window")
        XCTAssertEqual(Set(windows.keys), Set(RoomRotationRule.carriers))
    }

    func testOnlyAScheduledRuleHasAWindow() {
        XCTAssertFalse(RoomRotationRule.off.hasWindow)
        XCTAssertFalse(RoomRotationRule.automatic.hasWindow)
        for rule in schedule where rule != .off {
            XCTAssertTrue(rule.hasWindow, rule.rawValue)
        }
    }

    func testTheRowSummaryNamesTheWindowOnlyWhenOneApplies() {
        let language = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        defer { SettingsStore.shared.language = language }
        XCTAssertEqual(RoomRotationRule.summary(.daily, window: .anyTime), RoomRotationRule.daily.title)
        XCTAssertEqual(RoomRotationRule.summary(.daily, window: .night),
                       "\(RoomRotationRule.daily.title) · \(L10n.roomRotationWhenNightShort.localized())")
        XCTAssertEqual(RoomRotationRule.summary(.weekly, window: .hour(3)),
                       "\(RoomRotationRule.weekly.title) · \(L10n.roomRotationWhenHourShort_fmt.formatted("03:00"))")
        // Off and Automatic have no window to show.
        XCTAssertEqual(RoomRotationRule.summary(.off, window: .night), RoomRotationRule.off.title)
        XCTAssertEqual(RoomRotationRule.summary(.automatic, window: .hour(3)), RoomRotationRule.automatic.title)
    }

    func testAnHourIsShownOnTheTwentyFourHourClock() {
        XCTAssertEqual(RoomRotationWindow.hourLabel(0), "00:00")
        XCTAssertEqual(RoomRotationWindow.hourLabel(3), "03:00")
        XCTAssertEqual(RoomRotationWindow.hourLabel(23), "23:00")
    }

    func testEveryChoiceHasItsOwnTitle() {
        let titles = RoomRotationRule.allCases.map(\.title)
        XCTAssertFalse(titles.contains(""))
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testTheNoteUnderEachPickerDescribesItsProtocol() {
        XCTAssertEqual(RoomRotationRule.noteKey(for: "telemost"), .roomRotationNoteTelemost)
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            XCTAssertEqual(RoomRotationRule.noteKey(for: carrier), .roomRotationNoteSteady, carrier)
        }
        // MTS Link: the ordinary note once the app can make rooms, and why it
        // cannot before that.
        XCTAssertEqual(RoomRotationRule.noteKey(for: "mtslink", mtslinkCanCreate: true), .roomRotationNoteMtslinkPlan)
        XCTAssertEqual(RoomRotationRule.noteKey(for: "mtslink", mtslinkCanCreate: false), .roomRotationNoteMtslink)
    }
}

// MARK: - The pure decisions

final class RoomRotationPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func record(carrier: String,
                        bundle: Bool = false,
                        roomID: String = "room",
                        roomCreatedAt: Date? = nil) -> ConnectionRecord {
        var params = OlcrtcConnection(carrier: carrier, transport: "vp8channel",
                                      roomID: roomID, key: "k", clientID: "default")
        params.roomCreatedAt = roomCreatedAt
        if bundle { params.bundleLanes = [OlcrtcLane(carrier: "jitsi", transport: "datachannel", roomID: "j")] }
        return ConnectionRecord(name: carrier, details: .olcrtc(params))
    }

    private func params(of record: ConnectionRecord) -> OlcrtcConnection {
        guard case .olcrtc(let params) = record.details else { fatalError("Fixture must be OlcRTC") }
        return params
    }

    private func server(linking record: ConnectionRecord) -> ServerHost {
        var server = ServerHost(label: "Test host", host: "192.0.2.1")
        server.lastConnectionID = record.id
        return server
    }

    // MARK: Eligibility

    func testEveryProtocolWithARuleIsEligible() {
        for carrier in RoomRotationRule.carriers {
            XCTAssertTrue(RoomRotationPolicy.isEligible(record(carrier: carrier)), carrier)
        }
        XCTAssertFalse(RoomRotationPolicy.isEligible(record(carrier: "a-future-service")))
    }

    func testBundlesAndXrayRecordsAreNotEligible() {
        // A whole-server connection's rooms belong to the protocol records it
        // was derived from — those are what change, never the bundle itself.
        XCTAssertFalse(RoomRotationPolicy.isEligible(record(carrier: "vkcalls", bundle: true)))
        let xray = ConnectionRecord(name: "x",
                                    details: .xray(XrayConnection(host: "h", uuid: "u",
                                                                  sni: "s", publicKey: "k")))
        XCTAssertFalse(RoomRotationPolicy.isEligible(xray))
    }

    // MARK: What a rule covers

    func testAScheduleReachesVKSaluteJazzAndJitsi() {
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            let r = record(carrier: carrier)
            XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: []), 24, carrier)
            XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .weekly, exceptions: []), 168, carrier)
            XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: .off, exceptions: []), carrier)
        }
    }

    /// Telemost's Automatic belongs to TelemostRenewalCoordinator, and a
    /// schedule is not on its menu — nothing here ever covers it.
    func testTelemostNeverFollowsASchedule() {
        let r = record(carrier: "telemost")
        for rule in RoomRotationRule.allCases {
            XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: rule, exceptions: []), rule.rawValue)
        }
    }

    func testAnExceptedConnectionHasNoSchedule() {
        let r = record(carrier: "vkcalls")
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: []), 24)
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [r.id]))
        // Another connection's exception is none of this one's business.
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [UUID()]), 24)
    }

    func testWBStreamHasNoScheduleEvenIfOneWasSaved() {
        let r = record(carrier: "wbstream")
        XCTAssertFalse(RoomRotationPolicy.isEligible(r))
        for rule in RoomRotationRule.allCases {
            XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: rule, exceptions: []), rule.rawValue)
        }
    }

    func testBundlesAndXrayNeverHaveASchedule() {
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: record(carrier: "vkcalls", bundle: true),
                                                       rule: .daily, exceptions: []))
        let xray = ConnectionRecord(name: "x",
                                    details: .xray(XrayConnection(host: "h", uuid: "u",
                                                                  sni: "s", publicKey: "k")))
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: xray, rule: .daily, exceptions: []))
    }

    // MARK: The exceptions list

    func testTheExceptionsListHoldsManagedConnectionsWhoseProtocolIsOn() {
        let vk = record(carrier: "vkcalls")
        let jitsi = record(carrier: "jitsi")
        let telemost = record(carrier: "telemost")
        let wb = record(carrier: "wbstream")
        let imported = record(carrier: "vkcalls")           // no saved server holds it
        let whole = record(carrier: "vkcalls", bundle: true)  // a bundle is never listed
        var saved = server(linking: vk)
        saved.extraConnectionIDs = [jitsi.id, telemost.id, wb.id]
        saved.bundleConnectionID = whole.id

        let on: Set<String> = ["vkcalls", "telemost", "wbstream"]
        let listed = RoomRotationPolicy.exceptionCandidates(
            in: [vk, jitsi, telemost, wb, imported, whole], hosts: [saved], ruleIsOn: { on.contains($0) })
        // jitsi: its rule is off. wb: no longer a protocol with a rule. imported:
        // nobody here manages it. whole: a bundle.
        XCTAssertEqual(listed.map(\.id), [vk.id, telemost.id])
    }

    func testNothingIsListedWhileEveryRuleIsOff() {
        let vk = record(carrier: "vkcalls")
        XCTAssertTrue(RoomRotationPolicy.exceptionCandidates(
            in: [vk], hosts: [server(linking: vk)], ruleIsOn: { _ in false }).isEmpty)
    }

    func testAMemberOfSomeoneElsesServerAdministersNothing() {
        let r = record(carrier: "vkcalls")
        var saved = server(linking: r)
        saved.agentOnly = true
        saved.agentRole = "member"
        XCTAssertFalse(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        saved.agentRole = "owner"
        XCTAssertTrue(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        saved.agentOnly = nil
        saved.agentRole = nil
        XCTAssertTrue(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        XCTAssertFalse(RoomRotationPolicy.isManaged(r, hosts: []))
    }

    // MARK: The due decision

    private func decide(created: Date?, hours: Int, busy: Bool = false) -> RoomRotationPolicy.Decision {
        RoomRotationPolicy.decide(roomCreatedAt: created, intervalHours: hours, now: now, tunnelBusy: busy)
    }

    func testAnUnknownAgeIsNeverDue() {
        // A nil stamp is no evidence — the coordinator stamps one and starts
        // the clock; it does not guess the room is old.
        XCTAssertEqual(decide(created: nil, hours: 24), .notDue)
        XCTAssertEqual(decide(created: nil, hours: 24, busy: true), .notDue)
    }

    func testNoIntervalIsNeverDue() {
        XCTAssertEqual(decide(created: Date(timeIntervalSince1970: 0), hours: 0), .notDue)
    }

    func testARoomIsDueExactlyWhenItReachesItsInterval() {
        let daily = now.addingTimeInterval(-day)
        XCTAssertEqual(decide(created: daily, hours: 24), .rotate)
        XCTAssertEqual(decide(created: daily.addingTimeInterval(-1), hours: 24), .rotate)
        XCTAssertEqual(decide(created: daily.addingTimeInterval(1), hours: 24), .notDue)
        // A day-old room is not due on the weekly schedule.
        XCTAssertEqual(decide(created: daily, hours: 168), .notDue)
        XCTAssertEqual(decide(created: now.addingTimeInterval(-7 * day), hours: 168), .rotate)
    }

    func testABusyTunnelPostponesADueRoomButNotOneThatIsNotDue() {
        let due = now.addingTimeInterval(-day)
        XCTAssertEqual(decide(created: due, hours: 24, busy: true), .postpone)
        XCTAssertEqual(decide(created: due.addingTimeInterval(60), hours: 24, busy: true), .notDue)
    }

    func testAPostponedRoomIsForcedOnceItIsSixHoursOverdue() {
        let grace = RoomRotationPolicy.busyGrace
        XCTAssertEqual(grace, 6 * 3600, accuracy: 0)
        func overdue(by seconds: TimeInterval, hours: Int = 24) -> RoomRotationPolicy.Decision {
            decide(created: now.addingTimeInterval(-(TimeInterval(hours) * 3600 + seconds)),
                   hours: hours, busy: true)
        }
        XCTAssertEqual(overdue(by: 0), .postpone)
        XCTAssertEqual(overdue(by: grace - 1), .postpone)
        XCTAssertEqual(overdue(by: grace), .force)
        XCTAssertEqual(overdue(by: grace + 3600), .force)
        // The grace counts from when the room was due, whatever the interval.
        XCTAssertEqual(overdue(by: grace - 1, hours: 168), .postpone)
        XCTAssertEqual(overdue(by: grace, hours: 168), .force)
    }

    func testAQuietTunnelNeverWaits() {
        let longAgo = now.addingTimeInterval(-30 * day)
        XCTAssertEqual(decide(created: longAgo, hours: 24, busy: false), .rotate)
        XCTAssertEqual(decide(created: now.addingTimeInterval(-day), hours: 24, busy: false), .rotate)
    }

    func testEverySixAndTwelveHoursAndThreeDaysAreDueAtTheirInterval() {
        for rule in [RoomRotationRule.every6Hours, .every12Hours, .every3Days] {
            let hours = rule.intervalHours!
            let age = TimeInterval(hours) * 3600
            XCTAssertEqual(decide(created: now.addingTimeInterval(-age + 1), hours: hours), .notDue, rule.rawValue)
            XCTAssertEqual(decide(created: now.addingTimeInterval(-age), hours: hours), .rotate, rule.rawValue)
        }
    }

    func testARoomFromTheFutureIsNotDue() {
        XCTAssertEqual(decide(created: now.addingTimeInterval(day), hours: 24), .notDue)
    }

    // MARK: The window, in local time

    private let hour: TimeInterval = 3600

    private var moscow: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A local wall-clock time on 2026-10-21 plus `days` days, in `calendar`'s zone.
    private func at(_ h: Int, _ m: Int = 0, days: Int = 0, in calendar: Calendar? = nil) -> Date {
        let zone = calendar ?? moscow
        let base = zone.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: h, minute: m))!
        return zone.date(byAdding: .day, value: days, to: base)!
    }

    private func decide(_ rule: RoomRotationRule, created: Date?, now: Date, busy: Bool = false,
                        window: RoomRotationWindow) -> RoomRotationPolicy.Decision {
        RoomRotationPolicy.decide(roomCreatedAt: created, intervalHours: rule.intervalHours ?? 0, now: now,
                                  tunnelBusy: busy, window: window, calendar: moscow)
    }

    func testAnyTimeIsAlwaysInsideTheWindow() {
        for h in 0..<24 {
            XCTAssertTrue(RoomRotationPolicy.isInWindow(.anyTime, now: at(h), calendar: moscow), "\(h)")
        }
    }

    func testNightIsTwoToSixLocal() {
        func night(_ date: Date) -> Bool { RoomRotationPolicy.isInWindow(.night, now: date, calendar: moscow) }
        XCTAssertFalse(night(at(1, 59)))
        XCTAssertTrue(night(at(2, 0)))
        XCTAssertTrue(night(at(5, 59)))
        XCTAssertFalse(night(at(6, 0)))
        XCTAssertFalse(night(at(12, 0)))
        XCTAssertFalse(night(at(23, 30)))
    }

    func testAChosenHourIsThatWholeHourOnly() {
        func inside(_ window: RoomRotationWindow, _ date: Date) -> Bool {
            RoomRotationPolicy.isInWindow(window, now: date, calendar: moscow)
        }
        XCTAssertFalse(inside(.hour(3), at(2, 59)))
        XCTAssertTrue(inside(.hour(3), at(3, 0)))
        XCTAssertTrue(inside(.hour(3), at(3, 59)))
        XCTAssertFalse(inside(.hour(3), at(4, 0)))
        XCTAssertTrue(inside(.hour(0), at(0, 30)))
        XCTAssertTrue(inside(.hour(23), at(23, 59)))
    }

    func testTheWindowIsReadInTheZoneGiven() {
        // 23:30 UTC is 02:30 in Moscow: inside the night there, outside it in UTC.
        let instant = at(23, 30, in: utc)
        XCTAssertTrue(RoomRotationPolicy.isInWindow(.night, now: instant, calendar: moscow))
        XCTAssertFalse(RoomRotationPolicy.isInWindow(.night, now: instant, calendar: utc))
    }

    func testTheNightFollowsTheClockAcrossAChangeOfSummerTime() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func utcAt(_ h: Int, _ m: Int) -> Date {
            utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: h, minute: m))!
        }
        // 2026-10-25: 03:00 CEST becomes 02:00 CET, so 02:30 happens twice;
        // both are night, 06:00 CET is not.
        XCTAssertTrue(RoomRotationPolicy.isInWindow(.night, now: utcAt(0, 30), calendar: berlin))
        XCTAssertTrue(RoomRotationPolicy.isInWindow(.night, now: utcAt(1, 30), calendar: berlin))
        XCTAssertFalse(RoomRotationPolicy.isInWindow(.night, now: utcAt(5, 0), calendar: berlin))
    }

    // MARK: A due room and its window

    func testADueRoomOutsideItsWindowWaits() {
        let made = at(3, 30, days: -1)
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), window: .night), .waitForWindow)
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), window: .hour(3)), .waitForWindow)
    }

    func testADueRoomThatMissedItsWindowIsReplacedInTheNextOne() {
        let made = at(3, 30, days: -1)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(10, 0), window: .night), .waitForWindow)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(1, 59, days: 1), window: .night), .waitForWindow)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(2, 0, days: 1), window: .night), .rotate)
    }

    func testADueRoomInsideItsWindowIsReplacedAtOnce() {
        XCTAssertEqual(decide(.daily, created: at(3, 5, days: -1), now: at(3, 10), window: .hour(3)), .rotate)
        XCTAssertEqual(decide(.daily, created: at(4, 0, days: -1), now: at(4, 0), window: .night), .rotate)
    }

    func testARoomThatIsNotDueIsLeftAloneInsideAndOutsideItsWindow() {
        let made = at(3, 0)
        XCTAssertEqual(decide(.daily, created: made, now: at(3, 30), window: .hour(3)), .notDue)
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), window: .hour(3)), .notDue)
    }

    func testAnUnknownAgeIsNeverDueWhateverTheWindow() {
        XCTAssertEqual(decide(.daily, created: nil, now: at(15, 0), window: .night), .notDue)
        XCTAssertEqual(decide(.daily, created: nil, now: at(3, 0), window: .night), .notDue)
    }

    func testARuleWithNoScheduleIgnoresTheWindow() {
        XCTAssertEqual(decide(.off, created: at(0, 0, days: -30), now: at(15, 0), window: .night), .notDue)
        XCTAssertEqual(decide(.automatic, created: at(0, 0, days: -30), now: at(3, 0), window: .hour(3)), .notDue)
    }

    func testAChosenHourCountsARoomDueAnHourEarlySoADailyChangeDoesNotSlipADay() {
        // Changed at 03:50 yesterday: by 03:00 today it is 23 h 10 min old, and
        // the hour is today's only chance for a daily change.
        XCTAssertEqual(RoomRotationPolicy.dueAfter(intervalHours: 24, window: .hour(3)), day - hour, accuracy: 0)
        XCTAssertEqual(decide(.daily, created: at(3, 50, days: -1), now: at(3, 0), window: .hour(3)), .rotate)
        // Younger than that: not yet.
        XCTAssertEqual(decide(.daily, created: at(5, 0, days: -1), now: at(3, 0), window: .hour(3)), .notDue)
        // Any time and the night take the interval as it is.
        XCTAssertEqual(RoomRotationPolicy.dueAfter(intervalHours: 24, window: .anyTime), day, accuracy: 0)
        XCTAssertEqual(RoomRotationPolicy.dueAfter(intervalHours: 24, window: .night), day, accuracy: 0)
        XCTAssertEqual(RoomRotationPolicy.dueAfter(intervalHours: 6, window: .hour(3)), 5 * hour, accuracy: 0)
    }

    // MARK: Busy, the six hours, and the window

    func testABusyRoomInsideItsWindowWaitsUntilSixHoursOverdue() {
        // Every 6 h at night; made at 20:00, due at 02:00. The night is four
        // hours, so the cap cannot be reached inside it.
        let made = at(20, 0, days: -1)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(2, 0), busy: true, window: .night), .postpone)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(5, 59), busy: true, window: .night), .postpone)
        XCTAssertEqual(decide(.every6Hours, created: made, now: at(2, 0), busy: false, window: .night), .rotate)
    }

    func testTheSixHourCapNeverFiresOutsideTheWindow() {
        // Daily, made two days ago: a day overdue at 03:00 today. Busy at 15:00
        // (the cap long passed) it still waits for the window.
        let made = at(3, 0, days: -2)
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), busy: true, window: .hour(3)), .waitForWindow)
        XCTAssertEqual(decide(.daily, created: made, now: at(2, 59, days: 1), busy: true, window: .hour(3)), .waitForWindow)
    }

    func testABusyRoomThatMissedItsWindowIsForcedInTheNextOne() {
        let made = at(3, 0, days: -2)
        XCTAssertEqual(decide(.daily, created: made, now: at(3, 0, days: 1), busy: true, window: .hour(3)), .force)
    }

    func testTheCapCountsFromTheDueTimeTheWindowSets() {
        // Made at 10:00 yesterday. A chosen hour makes a daily room due an hour
        // early (09:00 today), and the six hours count from there.
        let made = at(10, 0, days: -1)
        XCTAssertEqual(decide(.daily, created: made, now: at(14, 59), busy: true, window: .hour(14)), .postpone)
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), busy: true, window: .hour(15)), .force)
        // Any time: due at 10:00, so 15:00 is five hours past it.
        XCTAssertEqual(decide(.daily, created: made, now: at(15, 0), busy: true, window: .anyTime), .postpone)
        XCTAssertEqual(decide(.daily, created: made, now: at(16, 0), busy: true, window: .anyTime), .force)
    }

    // MARK: How often a pass looks

    func testPassesLookEveryTenMinutesWhileAScheduledRuleHasAWindow() {
        let usual = RoomRotationPolicy.basePassInterval
        let windowed = RoomRotationPolicy.windowedPassInterval
        XCTAssertEqual(usual, 15 * 60, accuracy: 0)
        XCTAssertEqual(windowed, 10 * 60, accuracy: 0)
        func interval(_ rules: [String: RoomRotationRule], _ windows: [String: RoomRotationWindow]) -> TimeInterval {
            RoomRotationPolicy.passInterval(rules: rules, windows: windows)
        }
        XCTAssertEqual(interval(["vkcalls": .daily], [:]), usual, accuracy: 0)
        XCTAssertEqual(interval(["vkcalls": .daily], ["vkcalls": .anyTime]), usual, accuracy: 0)
        XCTAssertEqual(interval(["vkcalls": .daily], ["vkcalls": .night]), windowed, accuracy: 0)
        XCTAssertEqual(interval(["jitsi": .weekly], ["jitsi": .hour(4)]), windowed, accuracy: 0)
    }

    func testAWindowOnARuleWithNoScheduleDoesNotSpeedPassesUp() {
        XCTAssertEqual(RoomRotationPolicy.passInterval(rules: ["vkcalls": .off], windows: ["vkcalls": .night]),
                       RoomRotationPolicy.basePassInterval, accuracy: 0)
        XCTAssertEqual(RoomRotationPolicy.passInterval(rules: ["telemost": .automatic], windows: ["telemost": .night]),
                       RoomRotationPolicy.basePassInterval, accuracy: 0)
        // A window kept for one protocol says nothing about another's schedule.
        XCTAssertEqual(RoomRotationPolicy.passInterval(rules: ["vkcalls": .daily, "jitsi": .off],
                                                       windows: ["jitsi": .night]),
                       RoomRotationPolicy.basePassInterval, accuracy: 0)
    }

    // MARK: The live tunnel

    func testOnlyAMeasuredQuietProxySessionIsIdle() {
        let grace = RoomRotationPolicy.idleGrace
        XCTAssertEqual(grace, TelemostRenewalPolicy.idleGrace, accuracy: 0)
        func busy(observable: Bool, last: Date?) -> Bool {
            RoomRotationPolicy.isTunnelBusy(activityIsObservable: observable, lastActivity: last, now: now)
        }
        XCTAssertTrue(busy(observable: true, last: now.addingTimeInterval(-5)))
        XCTAssertTrue(busy(observable: true, last: now.addingTimeInterval(-(grace - 1))))
        XCTAssertFalse(busy(observable: true, last: now.addingTimeInterval(-grace)))
        XCTAssertFalse(busy(observable: true, last: now.addingTimeInterval(-3600)))
        // No measurement, or traffic the app cannot see (a VPN session, one
        // still connecting), is no evidence of rest.
        XCTAssertTrue(busy(observable: true, last: nil))
        XCTAssertTrue(busy(observable: false, last: now.addingTimeInterval(-3600)))
        XCTAssertTrue(busy(observable: false, last: nil))
    }

    func testALiveSessionRidesItsOwnRecordAndAWholeServerConnectionThatJoinedTheRoom() {
        let vk = record(carrier: "vkcalls", roomID: "https://vk.ru/call/join/AAA")
        let vkParams = params(of: vk)
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: nil, record: vk, params: vkParams))
        XCTAssertTrue(RoomRotationPolicy.isRiding(live: vk, record: vk, params: vkParams))

        let other = record(carrier: "vkcalls", roomID: "https://vk.ru/call/join/BBB")
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: other, record: vk, params: vkParams))

        var bundle = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/r", key: "k", clientID: "default")
        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/AAA")]
        let joined = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        XCTAssertTrue(RoomRotationPolicy.isRiding(live: joined, record: vk, params: vkParams))

        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/BBB")]
        let elsewhere = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: elsewhere, record: vk, params: vkParams))
    }

    // MARK: The "sign in again" silence window

    func testBlockedUntilTheRetryDelayPasses() {
        let until = now.addingTimeInterval(RoomRotationPolicy.signInRetryDelay)
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: nil, now: now))
        XCTAssertTrue(RoomRotationPolicy.isBlocked(blockedUntil: until, now: now))
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: until, now: until))
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: until,
                                                    now: until.addingTimeInterval(1)))
        XCTAssertEqual(RoomRotationPolicy.signInRetryDelay, 24.0 * 3600.0, accuracy: 0)
    }
}

// MARK: - The coordinator's pass

@MainActor
final class RoomRotationCoordinatorTests: XCTestCase {

    private enum Failure: Error { case unreachable }

    @MainActor
    private final class Fixture {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [ConnectionRecord] = []
        var rules: [String: RoomRotationRule] = [:]
        var windows: [String: RoomRotationWindow] = [:]
        /// `now` is 08:00 on this clock.
        var calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()
        var exceptions: Set<UUID> = []
        var managed = true
        var hasTarget = true
        var hostIsFree = true
        var engaged: ConnectionRecord?
        var connectedProxy = false
        var activity: Date?
        /// Thrown by the VK creator when set.
        var creationError: Error?
        /// Which creator ran, in order.
        var created: [String] = []
        /// The room each MTS Link creation was told is current.
        var mtsCurrent: [String] = []
        /// Whether the app can make MTS Link rooms (`canCreateMTSLinkRoom`).
        var mtsCanCreate = true
        /// The room each Jitsi creation was asked to stay near.
        var jitsiNear: [String] = []
        var applications: [InstallOptions] = []
        var updates: [ConnectionRecord] = []
        var disconnects = 0
        var connects: [ConnectionRecord] = []
        var claims = 0
        var releases = 0
        /// Overrides the server's confirmation; nil answers with a matching URI.
        var reply: ((InstallOptions) -> String?)?
        let host = ServerHost(label: "Test host", host: "192.0.2.1", lastContainerName: "olcrtc-test")

        static func confirmation(_ options: InstallOptions) -> String {
            "olcrtc://\(options.carrier)?\(options.transport)@\(options.roomID)#test-key"
        }

        @discardableResult
        func add(carrier: String, ageHours: Double?, roomID: String = "old-room") -> ConnectionRecord {
            var params = OlcrtcConnection(carrier: carrier,
                                          transport: CarrierTransportMatrix.defaultTransport(for: carrier),
                                          roomID: roomID, key: "test-key", clientID: "default")
            params.roomCreatedAt = ageHours.map { now.addingTimeInterval(-$0 * 3600) }
            let record = ConnectionRecord(name: "\(carrier) room", details: .olcrtc(params))
            records.append(record)
            return record
        }

        func params(of record: ConnectionRecord) -> OlcrtcConnection {
            guard let current = records.first(where: { $0.id == record.id }),
                  case .olcrtc(let params) = current.details else { fatalError("Fixture record missing") }
            return params
        }

        func makeCoordinator() -> RoomRotationCoordinator {
            RoomRotationCoordinator(environment: .init(
                records: { self.records },
                update: { record in
                    self.updates.append(record)
                    if let index = self.records.firstIndex(where: { $0.id == record.id }) {
                        self.records[index] = record
                    }
                },
                rule: { self.rules[$0] ?? .off },
                window: { self.windows[$0] ?? .anyTime },
                exceptions: { self.exceptions },
                isManaged: { _ in self.managed },
                target: { _ in
                    guard self.hasTarget else { return nil }
                    return .init(host: self.host, secret: .password("test-only"), container: "olcrtc-test")
                },
                createVKRoom: {
                    self.created.append("vkcalls")
                    if let error = self.creationError { throw error }
                    return "https://vk.ru/call/join/NEWVK"
                },
                createSaluteRoom: {
                    self.created.append("salutejazz")
                    return "abcd12:efgh3456"
                },
                createJitsiRoom: { current in
                    self.created.append("jitsi")
                    self.jitsiNear.append(current)
                    return "https://meet.example.org/olcrtc-newroom1"
                },
                canCreateMTSLinkRoom: { self.mtsCanCreate },
                createMTSLinkRoom: { current in
                    self.created.append("mtslink")
                    self.mtsCurrent.append(current)
                    return "https://my.mts-link.ru/j/1/222"
                },
                applyRoom: { _, options in
                    self.applications.append(options)
                    if let reply = self.reply { return reply(options) }
                    return Fixture.confirmation(options)
                },
                engagedRecord: { self.engaged },
                isConnectedProxy: { self.connectedProxy },
                lastActivity: { self.activity },
                disconnect: { self.disconnects += 1; self.engaged = nil },
                connect: { self.connects.append($0); self.engaged = $0 },
                now: { self.now },
                calendar: { self.calendar },
                claimHost: { _ in
                    self.claims += 1
                    return self.hostIsFree
                },
                releaseHost: { _ in self.releases += 1 },
                // Never ask the real accounts; the check has its own coverage.
                lastAccountCheck: { self.now },
                saveAccountCheck: { _ in }))
        }
    }

    // MARK: Every scheduled protocol

    func testEachScheduledProtocolGetsARoomFromItsOwnCreator() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        let salute = f.add(carrier: "salutejazz", ageHours: 25)
        let jitsi = f.add(carrier: "jitsi", ageHours: 25, roomID: "https://meet.example.org/olcrtc-oldroom1")
        f.rules = ["vkcalls": .daily, "salutejazz": .daily, "jitsi": .daily]

        await f.makeCoordinator().checkNow()

        XCTAssertEqual(f.created, ["vkcalls", "salutejazz", "jitsi"])
        XCTAssertEqual(f.applications.map(\.carrier), ["vkcalls", "salutejazz", "jitsi"])
        XCTAssertEqual(f.applications.map(\.roomID),
                       ["https://vk.ru/call/join/NEWVK", "abcd12:efgh3456",
                        "https://meet.example.org/olcrtc-newroom1"])
        XCTAssertEqual(f.params(of: vk).roomID, "https://vk.ru/call/join/NEWVK")
        XCTAssertEqual(f.params(of: salute).roomID, "abcd12:efgh3456")
        XCTAssertEqual(f.params(of: jitsi).roomID, "https://meet.example.org/olcrtc-newroom1")
        for record in [vk, salute, jitsi] {
            XCTAssertEqual(f.params(of: record).roomCreatedAt, f.now)
        }
        XCTAssertEqual(f.claims, 3)
        XCTAssertEqual(f.releases, 3)
    }

    func testTheJitsiRoomIsMadeOnTheServiceOfTheOldOne() async {
        let f = Fixture()
        f.add(carrier: "jitsi", ageHours: 25, roomID: "https://meet.example.org/olcrtc-oldroom1")
        f.rules = ["jitsi": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.jitsiNear, ["https://meet.example.org/olcrtc-oldroom1"])
    }

    /// MTS Link is rotated like VK Calls: the creator is told the room that is
    /// current (a replay that returns it is a failure), and the old meeting is
    /// left in the cabinet — no delete request is known.
    func testMTSLinkIsRotatedWithTheCurrentRoomKnown() async {
        let f = Fixture()
        let mts = f.add(carrier: "mtslink", ageHours: 25, roomID: "https://my.mts-link.ru/j/1/111")
        f.rules = ["mtslink": .daily]

        await f.makeCoordinator().checkNow()

        XCTAssertEqual(f.created, ["mtslink"])
        XCTAssertEqual(f.mtsCurrent, ["https://my.mts-link.ru/j/1/111"])
        XCTAssertEqual(f.applications.map(\.roomID), ["https://my.mts-link.ru/j/1/222"])
        XCTAssertEqual(f.params(of: mts).roomID, "https://my.mts-link.ru/j/1/222")
    }

    /// While the app cannot make a meeting there is nothing to rotate WITH, so
    /// the schedule does nothing (the `mtslinkCanCreate` gate in
    /// RoomRotationRule.allowed) — this is what the fixture's default flips on.
    func testMTSLinkIsLeftAloneWhileTheAppCannotMakeRooms() async {
        let f = Fixture()
        f.mtsCanCreate = false
        f.add(carrier: "mtslink", ageHours: 25, roomID: "https://my.mts-link.ru/j/1/111")
        f.rules = ["mtslink": .daily]

        await f.makeCoordinator().checkNow()

        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.applications.isEmpty)
    }

    func testTheWeeklyScheduleWaitsForAWeek() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 24 * 7 - 1)
        f.rules = ["vkcalls": .weekly]
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty)
        f.now = f.now.addingTimeInterval(3600)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
    }

    func testTheNewIntervalsRotateOnTheirOwnClock() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 6)
        f.add(carrier: "jitsi", ageHours: 71)
        f.rules = ["vkcalls": .every6Hours, "jitsi": .every3Days]
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        f.now = f.now.addingTimeInterval(3600)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls", "jitsi"])
    }

    func testADueRoomOutsideItsWindowWaitsForTheNextOne() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.windows = ["vkcalls": .night]
        let coordinator = f.makeCoordinator()

        await coordinator.checkNow()            // 08:00: outside the night
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertEqual(f.claims, 0, "a room waiting for its window asks no server")

        f.now = f.now.addingTimeInterval(18 * 3600)   // 02:00 the next day
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.params(of: vk).roomID, "https://vk.ru/call/join/NEWVK")
    }

    func testABusyTunnelIsNotForcedOutsideTheWindow() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 24 * 3)   // two days overdue
        f.rules = ["vkcalls": .daily]
        f.windows = ["vkcalls": .hour(9)]
        f.engaged = vk
        f.connectedProxy = true
        f.activity = f.now
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()            // 08:00
        XCTAssertTrue(f.created.isEmpty)
        f.now = f.now.addingTimeInterval(3600)  // 09:00: the window opens
        f.activity = f.now
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"], "long past the cap: replaced in the window although in use")
    }

    func testPassesLookMoreOftenWhileARuleHasAWindow() {
        let f = Fixture()
        f.rules = ["vkcalls": .daily]
        let coordinator = f.makeCoordinator()
        XCTAssertEqual(coordinator.passInterval(), RoomRotationPolicy.basePassInterval, accuracy: 0)
        f.windows = ["vkcalls": .night]
        XCTAssertEqual(coordinator.passInterval(), RoomRotationPolicy.windowedPassInterval, accuracy: 0)
    }

    func testTheRuleIsReadAtEveryPass() async {
        let f = Fixture()
        f.add(carrier: "salutejazz", ageHours: 30)
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "Off is the default: nothing runs")
        f.rules = ["salutejazz": .daily]
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["salutejazz"])
    }

    func testARoomThatIsNotDueIsLeftAlone() async {
        let f = Fixture()
        f.add(carrier: "jitsi", ageHours: 23)
        f.rules = ["jitsi": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    // MARK: Who is covered

    func testTelemostIsNeverRotatedHere() async {
        let f = Fixture()
        f.add(carrier: "telemost", ageHours: 30)
        f.rules = ["telemost": .automatic]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    func testAnExceptedConnectionKeepsItsRoom() async {
        let f = Fixture()
        let skipped = f.add(carrier: "vkcalls", ageHours: 25)
        let other = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.exceptions = [skipped.id]
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.params(of: skipped).roomID, "old-room")
        XCTAssertEqual(f.params(of: other).roomID, "https://vk.ru/call/join/NEWVK")
    }

    func testAnExceptedConnectionWithNoAgeIsNotEvenStamped() async {
        let f = Fixture()
        let skipped = f.add(carrier: "vkcalls", ageHours: nil)
        f.rules = ["vkcalls": .daily]
        f.exceptions = [skipped.id]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertNil(f.params(of: skipped).roomCreatedAt)
    }

    func testAConnectionThisPhoneDoesNotManageIsLeftToItsOwner() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.add(carrier: "jitsi", ageHours: nil)
        f.rules = ["vkcalls": .daily, "jitsi": .daily]
        f.managed = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.updates.isEmpty, "not even the quiet age stamp")
        XCTAssertEqual(f.claims, 0)
    }

    func testWBStreamIsNeverRotated() async {
        let f = Fixture()
        f.add(carrier: "wbstream", ageHours: 200)
        // Even a schedule forced into the environment does nothing.
        f.rules = ["wbstream": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    // MARK: Unknown ages, failures, silence

    func testAnUnknownAgeIsStampedQuietlyBeforeTheIntervalApplies() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: nil)
        f.rules = ["vkcalls": .daily]
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.params(of: vk).roomCreatedAt, f.now)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.claims, 0)

        f.now = f.now.addingTimeInterval(24 * 3600)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
    }

    func testAMissingServerSecretSkipsTheRoomWithoutCreatingOne() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.hasTarget = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.claims, 0)
    }

    func testAServerBusyWithSomethingElseDefersTheRotation() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.hostIsFree = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.releases, 0, "a claim that was refused is not released")
    }

    func testAFailedCreationKeepsTheRoomAndReleasesTheServer() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.creationError = Failure.unreachable
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertEqual(f.releases, 1)
    }

    func testAnUnconfirmedApplicationKeepsTheRecordsRoom() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-3600)   // quiet, so the room is not held back
        f.reply = { _ in nil }
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.applications.count, 1)
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertEqual(f.disconnects, 0)
        XCTAssertTrue(f.connects.isEmpty)
    }

    func testASignInFailureSilencesTheConnectionForADay() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.creationError = VKCallRoomError.sessionRejected
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        await coordinator.checkNow()
        XCTAssertEqual(f.created.count, 1, "retrying a refused sign-in every pass is noise")
        f.now = f.now.addingTimeInterval(RoomRotationPolicy.signInRetryDelay + 1)
        await coordinator.checkNow()
        XCTAssertEqual(f.created.count, 2)
    }

    // MARK: The live tunnel

    func testARotatedRoomThatTheLiveTunnelWasOnIsJoinedAgain() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-3600)   // quiet for an hour
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects.count, 1)
        XCTAssertEqual(f.connects.first?.id, vk.id)
        if case .olcrtc(let joined)? = f.connects.first?.details {
            XCTAssertEqual(joined.roomID, "https://vk.ru/call/join/NEWVK")
        } else {
            XCTFail("the tunnel was not connected again with the corrected record")
        }
    }

    func testABusyLiveTunnelPostponesTheRoomUntilItIsSixHoursOverdue() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 24)   // due this very moment
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        let coordinator = f.makeCoordinator()

        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "due, but the tunnel is in use")

        f.now = f.now.addingTimeInterval(6 * 3600 - 60)
        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "still inside the six hours")

        f.now = f.now.addingTimeInterval(60)
        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"], "six hours overdue: it goes regardless")
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects.count, 1)
    }

    func testAVPNSessionCountsAsBusyBecauseItsTrafficCannotBeSeen() async {
        let f = Fixture()
        let jitsi = f.add(carrier: "jitsi", ageHours: 24)
        f.rules = ["jitsi": .daily]
        f.engaged = jitsi
        f.connectedProxy = false
        f.activity = nil
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
    }

    func testATunnelOnAnotherConnectionDoesNotHoldARoomBack() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        let elsewhere = f.add(carrier: "jitsi", ageHours: 1)
        f.rules = ["vkcalls": .daily]
        f.engaged = elsewhere
        f.connectedProxy = true
        f.activity = f.now          // busy, but not on this room
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.disconnects, 0, "the user's session is not ours to replace")
        XCTAssertTrue(f.connects.isEmpty)
    }

    func testAWholeServerSessionThatJoinedTheRoomHoldsItBack() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 24, roomID: "https://vk.ru/call/join/AAA")
        var bundle = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/r", key: "test-key", clientID: "default")
        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/AAA")]
        let whole = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        f.records.append(whole)
        f.rules = ["vkcalls": .daily]
        f.engaged = whole
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-5)
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
    }
}
