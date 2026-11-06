import XCTest
@testable import olcrtc_ios

// How the Connections tab sorts connections: each of the user's own servers,
// the protocols a whole-server connection joins folded away unless asked for;
// each subscription with the servers it brought in; and the links added by
// hand, split by how the traffic travels.

final class ConnectionSectionsTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)

    private func call(_ name: String, _ carrier: String = "jitsi") -> ConnectionRecord {
        ConnectionRecord(name: name, details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: "datachannel", roomID: "room-\(name)", key: key, clientID: "default")))
    }

    private func direct(_ name: String) -> ConnectionRecord {
        ConnectionRecord(name: name, details: .xray(XrayConnection(
            host: "203.0.113.7", uuid: "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab",
            sni: "www.example.com", publicKey: "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc")))
    }

    func testLinksSplitByHowTheTrafficTravels() {
        let jitsi = call("shared")
        let nl = direct("NL")
        let sections = ConnectionSections.make(records: [jitsi, nl], hosts: [], covered: [], showFolded: false)
        XCTAssertEqual(sections.calls.map(\.id), [jitsi.id])
        XCTAssertEqual(sections.direct.map(\.id), [nl.id])
        XCTAssertTrue(sections.own.isEmpty)
        XCTAssertFalse(sections.isEmpty)
    }

    func testOwnServersKeepTheirRecordsInTheOrderTheServerProducedThem() {
        let primary = call("ams-1 · jitsi")
        let sibling = call("ams-1 · salutejazz", "salutejazz")
        let xray = direct("ams-1 · Xray")
        let shared = call("from a friend")
        var host = ServerHost(label: "ams-1", host: "203.0.113.7")
        host.lastConnectionID = primary.id
        host.extraConnectionIDs = [sibling.id]
        host.xrayConnectionID = xray.id
        let sections = ConnectionSections.make(records: [shared, xray, sibling, primary], hosts: [host],
                                               covered: [], showFolded: false)
        XCTAssertEqual(sections.own.map(\.label), ["ams-1"])
        XCTAssertEqual(sections.own.first?.records.map(\.id), [primary.id, sibling.id, xray.id])
        XCTAssertEqual(sections.calls.map(\.id), [shared.id], "a server's own records are not listed twice")
        XCTAssertTrue(sections.direct.isEmpty)
    }

    func testFoldedProtocolsComeBackOnlyWhenAskedFor() {
        let primary = call("ams-1 · jitsi")
        let sibling = call("ams-1 · salutejazz", "salutejazz")
        let bundle = call("ams-1")
        var host = ServerHost(label: "ams-1", host: "203.0.113.7")
        host.bundleConnectionID = bundle.id
        host.lastConnectionID = primary.id
        host.extraConnectionIDs = [sibling.id]
        let covered: Set<UUID> = [primary.id, sibling.id]
        let folded = ConnectionSections.make(records: [bundle, primary, sibling], hosts: [host],
                                             covered: covered, showFolded: false)
        XCTAssertEqual(folded.own.first?.records.map(\.id), [bundle.id])
        XCTAssertEqual(folded.foldedCount, 2)
        let shown = ConnectionSections.make(records: [bundle, primary, sibling], hosts: [host],
                                            covered: covered, showFolded: true)
        XCTAssertEqual(shown.own.first?.records.map(\.id), [bundle.id, primary.id, sibling.id])
    }

    func testWorkingDirectServersComeFirst() {
        let (a, b, c, d, e) = (direct("a"), direct("b"), direct("c"), direct("d"), direct("e"))
        let verdicts: [UUID: HealthDisplay] = [
            a.id: .broken(.keyMismatch, age: 5), b.id: .verified(ms: 300, age: 5),
            c.id: .never, d.id: .verified(ms: 40, age: 5), e.id: .fading(ms: 20, age: 600),
        ]
        let ordered = ConnectionSections.byHealth([a, b, c, d, e]) { verdicts[$0] ?? .never }
        XCTAssertEqual(ordered.map(\.name), ["d", "b", "e", "c", "a"])
    }

    func testSubscriptionServersLiveUnderTheirSubscriptionNotAmongTheLinks() {
        var listed = direct("from the list")
        listed.subSourceURL = "olcrtc-sub://lists.example.org/a"
        var orphan = direct("list forgotten")
        orphan.subSourceURL = "https://gone.example.org/b"
        let mine = direct("pasted")
        let sections = ConnectionSections.make(records: [listed, orphan, mine], hosts: [], covered: [],
                                               showFolded: false,
                                               subscriptions: ["https://lists.example.org/a"])
        XCTAssertEqual(sections.subscriptions.map(\.source), ["https://lists.example.org/a"])
        XCTAssertEqual(sections.subscriptions.first?.records.map(\.id), [listed.id],
                       "both link forms of one list are one subscription")
        XCTAssertEqual(sections.direct.map(\.id), [orphan.id, mine.id],
                       "a server whose list is unknown stays reachable among the links")
    }

    func testASubscriptionWithNoServersStillHasItsRow() {
        let sections = ConnectionSections.make(records: [], hosts: [], covered: [], showFolded: false,
                                               subscriptions: ["https://lists.example.org/a",
                                                               "olcrtc-sub://lists.example.org/a"])
        XCTAssertEqual(sections.subscriptions.map(\.source), ["https://lists.example.org/a"],
                       "the second link form of the same list is not a second row")
        XCTAssertTrue(sections.isEmpty, "a list with no servers is nothing to connect through")
    }

    func testCountsSayHowManyWorkAndHowManyWereChecked() {
        let (a, b, c, d) = (direct("a"), direct("b"), direct("c"), direct("d"))
        let verdicts: [UUID: HealthDisplay] = [
            a.id: .verified(ms: 40, age: 5), b.id: .fading(ms: 90, age: 900),
            c.id: .broken(.keyMismatch, age: 5),
        ]
        let counts = ConnectionSections.counts([a, b, c, d]) { verdicts[$0] ?? .never }
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.checked, 3, "the never-checked server is not counted as dead")
    }

    func testAServerWithoutConnectionsStillHasItsGroup() {
        let host = ServerHost(label: "fresh", host: "203.0.113.8")
        let sections = ConnectionSections.make(records: [], hosts: [host], covered: [], showFolded: false)
        XCTAssertEqual(sections.own.map(\.label), ["fresh"])
        XCTAssertTrue(sections.isEmpty, "nothing to connect through yet")
    }
}
