import XCTest
@testable import olcrtc_ios

// What the user may do with one subscription — switch it off, rename it,
// update it now, delete it — and what that means for the rest of the app: a
// switched-off list is neither refreshed by itself nor picked automatically,
// and what the user set survives every refresh. Also the words a subscription
// is shown with. The store runs on a private defaults suite; every record id
// created has its Keychain entries removed.

@MainActor
final class SubscriptionManagementTests: XCTestCase {

    private let suiteName = "olcos.subscription-management"
    private var defaults: UserDefaults!
    private var createdIDs: [UUID] = []
    private var savedLanguage = ""

    private let listA = "https://lists.example.org/a"
    private let listB = "https://lists.example.org/b"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        for id in createdIDs { ConnectionSecretStore.remove(connectionID: id) }
        createdIDs.removeAll()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: Fixtures

    private func body(name: String, rooms: [String], refresh: String? = nil) -> String {
        var lines = ["#name: \(name)"]
        if let refresh { lines.append("#refresh: \(refresh)") }
        for room in rooms {
            lines.append("olcrtc://wbstream?datachannel@\(room)#\(String(repeating: "a", count: 64))")
            lines.append("##name: \(room)")
        }
        return lines.joined(separator: "\n")
    }

    private func importList(_ store: ConnectionStore, _ source: String, name: String,
                            rooms: [String], refresh: String? = nil) {
        store.importSubscription(OlcrtcSubscription.parse(body(name: name, rooms: rooms, refresh: refresh)),
                                 source: source)
        createdIDs += store.connections.map(\.id)
    }

    private func manualRecord() -> ConnectionRecord {
        let record = ConnectionRecord(name: "pasted", details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: "mine",
            key: String(repeating: "b", count: 64), clientID: "default")))
        createdIDs.append(record.id)
        return record
    }

    // MARK: What the user sets survives a refresh

    func testARefreshKeepsTheUsersNameAndSwitch() {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "Pool", rooms: ["room-1", "room-2"])
        store.renameSubscription(listA, to: "  Work lists  ")
        store.setSubscription(listA, enabled: false)

        importList(store, listA, name: "Pool, renamed by its owner", rooms: ["room-1", "room-2", "room-3"])

        let meta = store.subscription(listA)
        XCTAssertEqual(meta?.customName, "Work lists", "trimmed, and kept across the refresh")
        XCTAssertEqual(meta?.isEnabled, false, "a refresh does not switch a list back on")
        XCTAssertEqual(meta?.name, "Pool, renamed by its owner", "the list's own name still updates")
        XCTAssertEqual(SubscriptionText.title(source: listA, meta: meta), "Work lists")
    }

    func testAnEmptyNameGivesTheListItsOwnNameBack() {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "Pool", rooms: ["room-1"])
        store.renameSubscription(listA, to: "Mine")
        store.renameSubscription(listA, to: "   ")
        XCTAssertNil(store.subscription(listA)?.customName)
        XCTAssertEqual(SubscriptionText.title(source: listA, meta: store.subscription(listA)), "Pool")
    }

    func testTheUsersSettingsArePersisted() {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "Pool", rooms: ["room-1"])
        store.renameSubscription(listA, to: "Mine")
        store.setSubscription(listA, enabled: false)
        let reloaded = ConnectionStore(defaults: defaults)
        XCTAssertEqual(reloaded.subscription(listA)?.customName, "Mine")
        XCTAssertEqual(reloaded.subscription(listA)?.isEnabled, false)
    }

    // MARK: A switched-off list

    func testASwitchedOffListIsNotRefreshedByItselfNorPickedAutomatically() {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "A", rooms: ["room-a"], refresh: "1h")
        importList(store, listB, name: "B", rooms: ["room-b"], refresh: "1h")
        let mine = manualRecord()
        store.add(mine)
        store.setSubscription(listA, enabled: false)

        let later = Date().addingTimeInterval(2 * 3600)
        XCTAssertEqual(store.dueSources(now: later), [listB], "both are due; only the switched-on one refreshes")

        let automatic = Set(store.automaticCandidates.map(\.id))
        XCTAssertFalse(store.records(ofSubscription: listA).contains { automatic.contains($0.id) })
        XCTAssertTrue(store.records(ofSubscription: listB).allSatisfy { automatic.contains($0.id) })
        XCTAssertTrue(automatic.contains(mine.id), "a link added by hand is always a candidate")

        store.setSubscription(listA, enabled: true)
        XCTAssertEqual(store.automaticCandidates.count, store.connections.count)
    }

    func testAPullRefreshesOnlySwitchedOnLists() async {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "A", rooms: ["room-a"])
        importList(store, listB, name: "B", rooms: ["room-b"])
        store.setSubscription(listA, enabled: false)
        var fetched: [String] = []
        let refreshed = await store.refreshAllSources(fetch: { url in
            fetched.append(url.absoluteString)
            return self.body(name: "B", rooms: ["room-b"])
        })
        XCTAssertEqual(fetched, [listB])
        XCTAssertEqual(refreshed, [listB])
    }

    // MARK: Updating one list now

    func testUpdatingOneListNowFetchesItEvenWhenSwitchedOff() async {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "A", rooms: ["room-a"])
        store.setSubscription(listA, enabled: false)
        let before = store.subscription(listA)?.lastRefresh
        let refreshed = await store.refreshSource(listA, fetch: { _ in
            self.body(name: "A", rooms: ["room-a", "room-a2"])
        })
        createdIDs += store.connections.map(\.id)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.records(ofSubscription: listA).count, 2)
        XCTAssertGreaterThanOrEqual(store.subscription(listA)?.lastRefresh ?? .distantPast, before ?? .distantFuture)
        XCTAssertEqual(store.subscription(listA)?.isEnabled, false, "updating is not switching on")
    }

    func testAFailedUpdateKeepsTheSavedServers() async {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "A", rooms: ["room-a", "room-b"])
        let refreshed = await store.refreshSource(listA, fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertFalse(refreshed)
        XCTAssertEqual(store.records(ofSubscription: listA).count, 2)
    }

    // MARK: Deleting a list

    func testDeletingAListForgetsItsServersAndItsBookkeeping() {
        let store = ConnectionStore(defaults: defaults)
        importList(store, listA, name: "A", rooms: ["room-a", "room-b"])
        importList(store, listB, name: "B", rooms: ["room-c"])
        let mine = manualRecord()
        store.add(mine)

        store.removeSubscription(listA)

        XCTAssertTrue(store.records(ofSubscription: listA).isEmpty)
        XCTAssertNil(store.subscription(listA), "no refresh can bring it back")
        XCTAssertEqual(store.records(ofSubscription: listB).count, 1, "the other list is untouched")
        XCTAssertTrue(store.connections.contains { $0.id == mine.id })
    }

    func testDeletingAListThatHeldNoServersStillForgetsIt() {
        let store = ConnectionStore(defaults: defaults)
        store.importSubscription(OlcrtcSubscription.parse("#name: Empty\n"), source: listA)
        XCTAssertNotNil(store.subscription(listA))
        store.removeSubscription(listA)
        XCTAssertNil(store.subscription(listA))
    }

    // MARK: The words a subscription is shown with

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testTheUpdateTimeIsAClockTimeNeverAnAge() {
        let now = date("2026-10-10T15:00:00Z")
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(SubscriptionText.updated(date("2026-10-10T14:32:00Z"), now: now, calendar: utc, locale: gb),
                       "Updated today at 14:32")
        XCTAssertEqual(SubscriptionText.updated(date("2026-10-09T22:10:00Z"), now: now, calendar: utc, locale: gb),
                       "Updated yesterday at 22:10")
        XCTAssertEqual(SubscriptionText.updated(date("2026-10-08T14:32:00Z"), now: now, calendar: utc, locale: gb),
                       "Updated 8 October at 14:32")
        XCTAssertEqual(SubscriptionText.updated(date("2025-10-08T14:32:00Z"), now: now, calendar: utc, locale: gb),
                       "Updated 8 October 2025 at 14:32")
    }

    func testTheWorkingFigureAppearsOnlyOnceSomethingWasChecked() {
        XCTAssertEqual(SubscriptionText.counts(servers: 42, working: 0, checked: 0), "Servers: 42")
        XCTAssertEqual(SubscriptionText.counts(servers: 42, working: 30, checked: 35), "Servers: 42 · working: 30")
    }

    func testAReadyMadeListIsCalledByItsTitleNotByTheProxyHost() {
        let curated = CuratedLists.all[0]
        XCTAssertEqual(SubscriptionText.title(source: curated.url, meta: nil), curated.title.localized())
        XCTAssertEqual(SubscriptionText.title(source: "https://lists.example.org/x?token=secret", meta: nil),
                       "lists.example.org", "never the full link")
    }
}
