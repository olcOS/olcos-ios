import XCTest
@testable import olcrtc_ios

// A subscription carries Xray (`vless://`) lines beside olcrtc ones, and a
// `##id` that names a node across room and key changes — so a list the admin
// phone republishes after renewing a Telemost room updates the connection a
// second phone already has instead of replacing it. Pure parse + diff; the
// store side is covered by SubscriptionDedupTests.

@MainActor
final class SubscriptionNodeIdentityTests: XCTestCase {

    private let source = "olcrtc-sub://share.example.org/s/abc"

    private func vless(uuid: String = "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab",
                       host: String = "203.0.113.7", port: Int = 443,
                       name: String = "vps") -> String {
        "vless://\(uuid)@\(host):\(port)?encryption=none&flow=xtls-rprx-vision&security=reality"
            + "&sni=www.example.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
            + "&sid=0427f68370c8885d&type=tcp#\(name)"
    }

    private func telemost(room: String, key: String = "aa") -> String {
        "olcrtc://telemost?vp8channel@\(room)#\(key)"
    }

    // MARK: Parse

    func testFieldsFollowTheLineAboveThem() {
        let sub = OlcrtcSubscription.parse("""
        #name: Home
        \(telemost(room: "111"))
        ##name: Telemost
        ##id: tm
        \(vless())
        ##name: Xray
        ##id: xr
        ##comment: direct
        """)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.xrayEntries.count, 1)
        XCTAssertEqual(sub.totalEntries, 2)
        XCTAssertFalse(sub.isEmpty)
        XCTAssertEqual(sub.entries[0].name, "Telemost")
        XCTAssertEqual(sub.entries[0].nodeID, "tm")
        XCTAssertNil(sub.entries[0].comment)
        XCTAssertEqual(sub.xrayEntries[0].recordName, "Xray")
        XCTAssertEqual(sub.xrayEntries[0].nodeID, "xr")
        XCTAssertEqual(sub.xrayEntries[0].comment, "direct")
        XCTAssertEqual(sub.xrayEntries[0].parsed.params.host, "203.0.113.7")
    }

    func testXrayNameFallsBackToTheLinkFragment() {
        let sub = OlcrtcSubscription.parse(vless(name: "ams"))
        XCTAssertEqual(sub.xrayEntries.first?.recordName, "ams")
    }

    func testBrokenVlessLineIsSkippedNotFatal() {
        let sub = OlcrtcSubscription.parse("vless://nope\n\(vless())")
        XCTAssertEqual(sub.xrayEntries.count, 1)
        XCTAssertEqual(sub.skippedURIs, 1)
    }

    func testAListOfOnlyXrayLinesIsASubscriptionBody() {
        let body = vless(name: "a") + "\n" + vless(uuid: "1f6a4b3e-2a9c-4f1e-9e8f-0123456789ab", name: "b")
        XCTAssertEqual(OlcrtcSubscription.detectImport(body), .subscriptionBody(body))
    }

    func testNodeIDReplacesTheConnectionFieldsAsKey() {
        let a = OlcrtcSubscription.parse("\(telemost(room: "111"))\n##id: tm").entries[0]
        let b = OlcrtcSubscription.parse("\(telemost(room: "222", key: "bb"))\n##id: tm").entries[0]
        XCTAssertEqual(a.nodeKey, b.nodeKey)
        let plain = OlcrtcSubscription.parse(telemost(room: "111")).entries[0]
        XCTAssertNotEqual(plain.nodeKey, a.nodeKey)
    }

    // MARK: Diff

    func testRenewedRoomUpdatesTheSameRecord() throws {
        let first = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse("\(telemost(room: "111"))\n##id: tm"),
            source: source, group: "Home", existing: [])
        let saved = try XCTUnwrap(first.toAdd.first)

        let renewed = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse("\(telemost(room: "222", key: "bb"))\n##id: tm"),
            source: source, group: "Home", existing: [saved])
        XCTAssertTrue(renewed.toAdd.isEmpty)
        XCTAssertTrue(renewed.toRemove.isEmpty)
        let updated = try XCTUnwrap(renewed.toUpdate.first)
        XCTAssertEqual(updated.id, saved.id)
        guard case .olcrtc(let p) = updated.details else { return XCTFail("kind changed") }
        XCTAssertEqual(p.roomID, "222")
        XCTAssertEqual(p.key, "bb")
    }

    func testXrayNodesAreAddedUpdatedAndRemoved() throws {
        let first = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse(vless()), source: source, group: "Home", existing: [])
        let saved = try XCTUnwrap(first.toAdd.first)
        guard case .xray = saved.details else { return XCTFail("not an Xray record") }

        // New account on the same endpoint: the same node, updated in place.
        let rotated = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse(vless(uuid: "2f6a4b3e-2a9c-4f1e-9e8f-0123456789ab")),
            source: source, group: "Home", existing: [saved])
        XCTAssertEqual(rotated.toUpdate.map(\.id), [saved.id])
        XCTAssertTrue(rotated.toAdd.isEmpty)
        XCTAssertTrue(rotated.toRemove.isEmpty)

        // Gone from the list: removed.
        let emptied = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse(telemost(room: "111")),
            source: source, group: "Home", existing: [saved])
        XCTAssertEqual(emptied.toRemove, [saved.id])
    }

    /// Two accounts on one endpoint, the first re-issued: the fallback must not
    /// take the record the second account still matches exactly.
    func testFallbackNeverTakesARecordAnotherNodeMatchesExactly() throws {
        let uuidA = "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab"
        let uuidB = "1f6a4b3e-2a9c-4f1e-9e8f-0123456789ab"
        let first = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse(vless(uuid: uuidA, name: "a") + "\n" + vless(uuid: uuidB, name: "b")),
            source: source, group: "Home", existing: [])
        XCTAssertEqual(first.toAdd.count, 2)
        let recordA = first.toAdd[0], recordB = first.toAdd[1]

        let uuidA2 = "3f6a4b3e-2a9c-4f1e-9e8f-0123456789ab"
        let next = ConnectionStore.diffSubscription(
            OlcrtcSubscription.parse(vless(uuid: uuidA2, name: "a") + "\n" + vless(uuid: uuidB, name: "b")),
            source: source, group: "Home", existing: [recordA, recordB])
        XCTAssertTrue(next.toAdd.isEmpty)
        XCTAssertTrue(next.toRemove.isEmpty)
        XCTAssertEqual(next.toUpdate.map(\.id), [recordA.id])
        guard case .xray(let p) = next.toUpdate.first?.details else { return XCTFail("not an Xray record") }
        XCTAssertEqual(p.uuid, uuidA2)
    }

    /// A connection through an invite failed: its list is fetched again at
    /// once (the server may have moved to a new room), but not more often
    /// than once a minute, and never for an ordinary subscription.
    func testFailedInviteConnectionRefetchesItsListOncePerMinute() async throws {
        let suite = "olcos.tests.invite-refresh"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults)
        let source = InviteLink.source(host: "203.0.113.7", port: 38471,
                                       token: "0123456789abcdef0123456789abcdef")
        store.importSubscription(OlcrtcSubscription.parse("\(telemost(room: "111"))\n##id: tm"), source: source)
        defer { for r in store.connections { ConnectionSecretStore.remove(connectionID: r.id) } }
        let savedID = try XCTUnwrap(store.connections.first?.id)

        var fetches = 0
        let renewed = "\(telemost(room: "222"))\n##id: tm"
        let now = Date()
        let first = await store.refreshInviteAfterFailure(source: source, now: now) { _ in
            fetches += 1
            return renewed
        }
        XCTAssertTrue(first)
        XCTAssertEqual(store.connections.map(\.id), [savedID])
        guard case .olcrtc(let p) = store.connections.first?.details else { return XCTFail("kind changed") }
        XCTAssertEqual(p.roomID, "222")

        let again = await store.refreshInviteAfterFailure(source: source, now: now.addingTimeInterval(30)) { _ in
            fetches += 1
            return renewed
        }
        XCTAssertFalse(again)
        XCTAssertEqual(fetches, 1)
        let ordinary = await store.refreshInviteAfterFailure(source: "olcrtc-sub://pool.example.org/sub")
        XCTAssertFalse(ordinary)
    }

    func testPlainImportFindsASavedXrayNode() throws {
        let params = try XrayURI.parse(vless()).params
        let saved = ConnectionRecord(name: "vps", details: .xray(params))
        XCTAssertEqual(MainTabView.existingXrayRecord(matching: params, in: [saved])?.id, saved.id)
        var other = params
        other.uuid = "4f6a4b3e-2a9c-4f1e-9e8f-0123456789ab"
        XCTAssertNil(MainTabView.existingXrayRecord(matching: other, in: [saved]))
    }
}
