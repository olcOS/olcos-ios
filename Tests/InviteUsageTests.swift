import XCTest
@testable import olcrtc_ios

// How invited devices are told apart, and what Manage server → Devices makes
// of the agent's usage: the invite tag (DeviceInvite.tag), the invite's links
// in its list (InvitePayload), the id an install announces
// (DeviceIdentity.effectiveClientID), and the matching, sums and words of
// InviteUsage. All pure; the agent call itself is integration-only.

@MainActor
final class InviteUsageTests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "ru"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        SettingsStore.flushPendingWrites()
        super.tearDown()
    }

    // MARK: Tag

    /// The Android app derives the same tag: pinned against SHA-256 itself.
    func testTagIsTheStartOfTheTokensSHA256() {
        let token = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(DeviceInvite.tag(forToken: token), "3eb1bd43")
        XCTAssertEqual(DeviceInvite.tag(forToken: String(repeating: "f", count: 32)), "35230248")
        let invite = DeviceInvite(name: "iPad", token: token)
        XCTAssertEqual(invite.tag, "3eb1bd43")
        XCTAssertEqual(invite.clientID, "inv-3eb1bd43")
        XCTAssertFalse(invite.clientID.contains(token), "the token itself never leaves the phone")
        // Every fresh invite's id has the shape the engines recognise.
        for _ in 0..<20 {
            XCTAssertTrue(DeviceIdentity.isInviteClientID(DeviceInvite(name: "x").clientID))
        }
    }

    func testAnInvitesListPutsTheInviteOnEveryOlcrtcLink() throws {
        let key = String(repeating: "ab", count: 32)
        let telemost = ConnectionRecord(name: "ams · Telemost", details: .olcrtc(OlcrtcConnection(
            from: try OlcrtcURI.parse("olcrtc://telemost?vp8channel@32559374476312#\(key)%my-phone"))))
        let xray = ConnectionRecord(name: "ams · Xray", details: .xray(try XrayURI.parse(
            "vless://0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab@203.0.113.7:443?encryption=none"
            + "&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome"
            + "&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0427f68370c8885d&type=tcp").params))
        let invite = DeviceInvite(name: "iPad", token: "0123456789abcdef0123456789abcdef")

        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [telemost, xray],
                                                    inviteTag: invite.tag))
        XCTAssertTrue(body.contains("#\(key)%inv-3eb1bd43\n"), body)
        XCTAssertFalse(body.contains("%my-phone"), "the admin's own clientID never travels")
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.first?.parsed.clientID, "inv-3eb1bd43")
        XCTAssertEqual(sub.xrayEntries.count, 1, "Xray links are unchanged")
        // Without an invite the links keep the placeholder.
        let plain = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [telemost]))
        XCTAssertEqual(OlcrtcSubscription.parse(plain).entries.first?.parsed.clientID, DeviceIdentity.placeholder)
        // Two invites, two different lists: each one's digest is its own.
        let other = DeviceInvite(name: "Phone", token: String(repeating: "f", count: 32))
        let otherBody = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [telemost],
                                                         inviteTag: other.tag))
        XCTAssertNotEqual(InvitePayload.digest(otherBody), InvitePayload.digest(plain))
    }

    /// The publisher builds each invite's list with that invite's own id.
    func testInviteSyncGivesEachInviteItsOwnId() throws {
        let suite = "InviteUsageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let savedStore = ConnectionStore.shared
        let record = ConnectionRecord(name: "ams · Jitsi", details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: "https://meet.example.org/room",
            key: String(repeating: "ab", count: 32), clientID: "default")))
        defer {
            ConnectionSecretStore.remove(connectionID: record.id)
            defaults.removePersistentDomain(forName: suite)
            ConnectionStore.shared = savedStore
        }
        let connections = ConnectionStore(defaults: defaults)
        connections.connections = [record]
        var host = ServerHost(label: "ams", host: "203.0.113.7")
        host.lastConnectionID = record.id
        let tablet = DeviceInvite(name: "iPad", token: "0123456789abcdef0123456789abcdef")
        let phone = DeviceInvite(name: "Phone", token: String(repeating: "f", count: 32))
        host.invites = [tablet, phone]
        let sync = InviteSync(connections: connections, hosts: ServerHostStore(defaults: defaults))

        let tabletList = try XCTUnwrap(sync.currentList(for: host, invite: tablet))
        let phoneList = try XCTUnwrap(sync.currentList(for: host, invite: phone))
        XCTAssertTrue(tabletList.contains("%inv-3eb1bd43\n"), tabletList)
        XCTAssertTrue(phoneList.contains("%inv-35230248\n"), phoneList)
        XCTAssertNotEqual(InvitePayload.digest(tabletList), InvitePayload.digest(phoneList))
    }

    // MARK: The id an install announces

    func testAnInviteIdIsAnnouncedWithThisInstallsName() {
        let me = "quiet-harbor-42"
        XCTAssertEqual(DeviceIdentity.effectiveClientID("inv-1a2b3c4d", deviceID: me), "inv-1a2b3c4d-quiet-harbor-42")
        XCTAssertEqual(DeviceIdentity.effectiveClientID(" inv-1a2b3c4d\n", deviceID: me), "inv-1a2b3c4d-quiet-harbor-42")
        // Two installs of one invite never share an identity.
        XCTAssertNotEqual(DeviceIdentity.effectiveClientID("inv-1a2b3c4d", deviceID: me),
                          DeviceIdentity.effectiveClientID("inv-1a2b3c4d", deviceID: "amber-lark-17"))
        // Every engine entry point (start, check, ping, the VPN config) resolves through this.
        let stored = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/room",
                                      key: String(repeating: "a", count: 64), clientID: "inv-1a2b3c4d")
        XCTAssertEqual(DeviceIdentity.resolving(stored, deviceID: me).clientID, "inv-1a2b3c4d-quiet-harbor-42")
        XCTAssertEqual(stored.clientID, "inv-1a2b3c4d", "the record keeps the invite's id")
    }

    func testAnyOtherClientIDBehavesAsBefore() {
        let me = "quiet-harbor-42"
        XCTAssertEqual(DeviceIdentity.effectiveClientID("default", deviceID: me), me)
        XCTAssertEqual(DeviceIdentity.effectiveClientID("", deviceID: me), me)
        for id in ["inv-1A2B3C4D",                  // uppercase
                   "inv-1a2b3c4",                   // 7 digits
                   "inv-1a2b3c4d5",                 // 9 digits
                   "inv-1a2b3c4g",                  // not hex
                   "inv-１２３４５６７８",           // fullwidth digits
                   "xinv-1a2b3c4d", "inv1a2b3c4d",
                   "inv-1a2b3c4d-quiet-harbor-42",  // already composed: never twice
                   "phone-2", "olc-ping-B1B91495"] {
            XCTAssertFalse(DeviceIdentity.isInviteClientID(id), id)
            XCTAssertEqual(DeviceIdentity.effectiveClientID(id, deviceID: me), id, id)
        }
    }

    // MARK: Matching and sums

    private func device(_ id: String, seen: Int64, online: Bool = false,
                        sent: Int64 = 0, received: Int64 = 0) -> AgentUsage.Device {
        AgentUsage.Device(id: id, lastSeen: seen, online: online, bytesIn: sent, bytesOut: received, sessions: 1)
    }

    func testEveryInstallOfTheInviteAddsUp() {
        let usage = AgentUsage(at: 1_760_000_000, devices: [
            device("inv-1a2b3c4d-quiet-harbor-42", seen: 1_760_000_000, online: true, sent: 85, received: 1_200),
            device("inv-1a2b3c4d-amber-lark-17", seen: 1_759_990_000, sent: 15, received: 800),
            device("inv-1a2b3c4d", seen: 1_759_000_000, sent: 1, received: 1),   // an app that sends the bare id
            device("inv-1a2b3c4e-quiet-harbor-42", seen: 1_760_000_100, online: true, sent: 9, received: 9),
            device("inv-1a2b3c4dd-x", seen: 1_760_000_100, sent: 9, received: 9),
            device("quiet-harbor-42", seen: 1_760_000_100, online: true, sent: 9, received: 9),
        ])
        let summary = InviteUsage.summary(tag: "1a2b3c4d", in: usage)
        XCTAssertEqual(summary.installs, 3)
        XCTAssertTrue(summary.online)
        XCTAssertEqual(summary.lastSeen, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(summary.sent, 101, "↑ is what the devices sent: the agent's `in`")
        XCTAssertEqual(summary.received, 2_001, "↓ is what they received: the agent's `out`")

        XCTAssertTrue(InviteUsage.matches("inv-1a2b3c4d-x", tag: "1a2b3c4d"))
        XCTAssertFalse(InviteUsage.matches("inv-1a2b3c4dx", tag: "1a2b3c4d"))
        XCTAssertFalse(InviteUsage.matches("xinv-1a2b3c4d-x", tag: "1a2b3c4d"))
    }

    func testAnInviteNobodyTookReadsNotYetConnected() {
        let usage = AgentUsage(at: 1, devices: [device("quiet-harbor-42", seen: 1, online: true)])
        let summary = InviteUsage.summary(tag: "1a2b3c4d", in: usage)
        XCTAssertEqual(summary, .empty)
        XCTAssertEqual(summary.statusText(), "Ещё не подключалось")
        XCTAssertEqual(InviteUsage.summary(tag: "1a2b3c4d", in: AgentUsage(at: 1, devices: [])), .empty)
    }

    func testSumsSaturateInsteadOfWrapping() {
        let usage = AgentUsage(at: 1, devices: [
            device("inv-1a2b3c4d-a", seen: 1, sent: .max, received: -5),
            device("inv-1a2b3c4d-b", seen: 1, sent: 10, received: 3),
        ])
        let summary = InviteUsage.summary(tag: "1a2b3c4d", in: usage)
        XCTAssertEqual(summary.sent, .max)
        XCTAssertEqual(summary.received, 3, "a negative count from the server adds nothing")
    }

    // MARK: Words

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10, year: Int = 2026) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A clock time in the app language, never an age that goes stale on screen.
    func testLastConnectedIsAClockTime() {
        let now = date(14, 15, 40)
        let today = InviteUsage.clock(date(14, 14, 32), now: now, calendar: utc)
        XCTAssertEqual(today, "сегодня в 14:32")
        let yesterday = InviteUsage.clock(date(13, 9, 10), now: now, calendar: utc)
        XCTAssertEqual(yesterday, "вчера в 09:10")
        let earlier = InviteUsage.clock(date(12, 18, 5), now: now, calendar: utc)
        XCTAssertTrue(earlier.hasPrefix("12 окт"), earlier)
        XCTAssertTrue(earlier.hasSuffix(" в 18:05"), earlier)
        XCTAssertFalse(earlier.contains("2026"), "this year's date carries no year")
        let lastYear = InviteUsage.clock(date(12, 18, 5, year: 2025), now: now, calendar: utc)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
        for phrase in [today, yesterday, earlier] {
            XCTAssertFalse(phrase.contains("назад"), phrase)
        }

        let seen = InviteUsage(installs: 1, online: false, lastSeen: date(14, 14, 32), received: 0, sent: 0)
        XCTAssertEqual(seen.statusText(now: now, calendar: utc), "Последнее подключение: сегодня в 14:32")
        var online = seen
        online.online = true
        XCTAssertEqual(online.statusText(now: now, calendar: utc), "Сейчас подключено")

        SettingsStore.shared.language = "en"
        let english = InviteUsage.clock(date(13, 9, 10), now: now, calendar: utc)
        XCTAssertTrue(english.hasPrefix("yesterday at "), english)
        XCTAssertFalse(english.contains("ago"), english)
        XCTAssertTrue(InviteUsage.clock(date(14, 14, 32), now: now, calendar: utc).hasPrefix("today at "))
    }

    func testByteCountsFollowTheAppLanguage() {
        let russian = InviteUsage.bytes(1_200_000_000)
        XCTAssertTrue(russian.contains("ГБ"), russian)
        SettingsStore.shared.language = "en"
        let english = InviteUsage.bytes(1_200_000_000)
        XCTAssertTrue(english.contains("GB"), english)
        XCTAssertNotEqual(russian, english)
        XCTAssertFalse(InviteUsage.bytes(0).lowercased().contains("zero"), InviteUsage.bytes(0))
    }

    func testDeviceCountsUseThePluralOfTheLanguage() {
        let forms: [(Int, InviteUsage.PluralForm)] = [
            (1, .one), (2, .few), (4, .few), (5, .many), (11, .many), (12, .many), (14, .many),
            (21, .one), (22, .few), (25, .many), (101, .one), (111, .many), (112, .many),
        ]
        for (n, form) in forms {
            XCTAssertEqual(InviteUsage.pluralForm(n, language: .russian), form, "\(n)")
        }
        XCTAssertEqual(InviteUsage.installsText(2), "2 устройства")
        XCTAssertEqual(InviteUsage.installsText(5), "5 устройств")
        XCTAssertEqual(InviteUsage.installsText(21), "21 устройство")
        XCTAssertEqual(InviteUsage.pluralForm(1, language: .english), .one)
        XCTAssertEqual(InviteUsage.pluralForm(2, language: .english), .many)
        XCTAssertEqual(InviteUsage.pluralForm(0, language: .french), .one)
        XCTAssertEqual(InviteUsage.pluralForm(2, language: .french), .many)
        SettingsStore.shared.language = "en"
        XCTAssertEqual(InviteUsage.installsText(2), "2 devices")
        SettingsStore.shared.language = "fr"
        XCTAssertEqual(InviteUsage.installsText(3), "3 appareils")
    }

    // MARK: The agent's answer

    func testTheAgentsAnswerDecodes() throws {
        let json = """
        {"at":1760446742,"devices":[{"id":"inv-3eb1bd43-quiet-harbor-42","last_seen":1760446740,\
        "online":true,"in":85000000,"out":1200000000,"sessions":14}]}
        """
        let usage = try JSONDecoder().decode(AgentUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.at, 1_760_446_742)
        XCTAssertEqual(usage.devices, [AgentUsage.Device(id: "inv-3eb1bd43-quiet-harbor-42", lastSeen: 1_760_446_740,
                                                         online: true, bytesIn: 85_000_000,
                                                         bytesOut: 1_200_000_000, sessions: 14)])
    }
}
