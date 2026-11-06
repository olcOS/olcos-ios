import XCTest
@testable import olcrtc_ios

// Free-server lists: the ready-made lists the «+» menu offers, and the search
// for a working server among many. The TCP knocks and the full checks are
// network work, integration-only; the ranking and the choice of what to knock
// on are pure.

final class BestServerSearchTests: XCTestCase {

    func testRanksTheServersThatAnsweredFastestFirst() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        XCTAssertEqual(BestServerSearch.ranked([(a, 120), (b, nil), (c, 40), (d, 120)]), [c, a, d],
                       "a server that did not answer is never tried; equal times keep the list order")
        XCTAssertEqual(BestServerSearch.ranked([(a, nil)]), [])
    }

    func testOnlyDirectServersAreKnockedOn() {
        let direct = ConnectionRecord(name: "NL", details: .xray(XrayConnection(
            host: "203.0.113.7", port: 8443, uuid: "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab",
            sni: "www.example.com", publicKey: "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc")))
        let endpoint = BestServerSearch.endpoint(of: direct)
        XCTAssertEqual(endpoint?.host, "203.0.113.7")
        XCTAssertEqual(endpoint?.port, 8443)
        let call = ConnectionRecord(name: "ams-1", details: .olcrtc(OlcrtcConnection(
            carrier: "telemost", transport: "vp8channel", roomID: "90465372891949",
            key: String(repeating: "ab", count: 32), clientID: "default")))
        XCTAssertNil(BestServerSearch.endpoint(of: call), "a call protocol's rendezvous is not the server")
    }

    @MainActor
    func testAnAutomaticSweepLeavesMostOfABigListAlone() {
        let health = HealthCoordinator.shared
        health._resetForTesting()
        defer { health._resetForTesting() }
        func direct(_ n: Int) -> ConnectionRecord {
            ConnectionRecord(name: "free \(n)", details: .xray(XrayConnection(
                host: "198.51.100.\(n)", uuid: "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab",
                sni: "www.example.com", publicKey: "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc")))
        }
        let list = (1...30).map(direct)
        let call = ConnectionRecord(name: "ams-1", details: .olcrtc(OlcrtcConnection(
            carrier: "telemost", transport: "vp8channel", roomID: "90465372891949",
            key: String(repeating: "ab", count: 32), clientID: "default")))
        for record in list.prefix(12) { health.noteLiveVerified(recordID: record.id, rttMs: 80) }
        let due = health.automaticSweepCandidates([call] + list, keep: [list[29].id])
        XCTAssertTrue(due.contains { $0.id == call.id }, "call protocols are always checked")
        XCTAssertTrue(due.contains { $0.id == list[29].id }, "the one in use is always checked")
        XCTAssertEqual(due.count, 1 + 1 + HealthCoordinator.automaticDirectLimit,
                       "of the rest, only servers that worked last time, and only a few")
        XCTAssertFalse(due.contains { $0.id == list[20].id }, "an unchecked free server waits for a pull or the search")
    }

    /// A protocol whose room the whole-server connection holds is not checked
    /// on opening: the whole-server record speaks for it.
    @MainActor
    func testAnAutomaticSweepLeavesCoveredProtocolsToTheirServer() {
        let health = HealthCoordinator.shared
        health._resetForTesting()
        defer { health._resetForTesting() }
        let call = ConnectionRecord(name: "ams-1 · Jitsi", details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: "https://meet.example/a",
            key: String(repeating: "ab", count: 32), clientID: "default")))
        let due = health.automaticSweepCandidates([call], keep: [], covered: [call.id])
        XCTAssertTrue(due.isEmpty)
    }

    func testTheReadyMadeListsImportAsSubscriptions() throws {
        XCTAssertEqual(Set(CuratedLists.all.map(\.id)).count, CuratedLists.all.count)
        for entry in CuratedLists.all {
            let url = try XCTUnwrap(URL(string: entry.url), entry.id)
            XCTAssertEqual(url.scheme, "https", entry.id)
            guard case .subscriptionURL = OlcrtcSubscription.detectImport(entry.url) else {
                return XCTFail("\(entry.id) must import as a subscription")
            }
        }
        // The white lists go through Yandex Translate's page proxy, which a
        // white-listed mobile network still lets through.
        XCTAssertTrue(CuratedLists.all.filter { $0.id.hasPrefix("white") }
            .allSatisfy { $0.url.hasPrefix("https://translate.yandex.ru/translate?url=") })
    }
}
