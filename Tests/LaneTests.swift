import Network
import XCTest
@testable import olcrtc_ios

// Several rooms at once ("lanes"): how the server's extra rooms are told apart
// from its protocols, how they reach the connection, the list and an invite,
// and which room takes the next connection. The relay itself and the parallel
// runtimes are integration-only (checked on a VPS: two SaluteJazz rooms
// carried twice what one did).

@MainActor
final class LaneTests: XCTestCase {

    private func row(_ file: String, provider: String, room: String = "r",
                     primary: Bool = false) -> SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(file: file, provider: provider, transport: "datachannel", room: room,
                              container: "olcrtc-server-x" + (primary ? "" : "-" + file),
                              status: .running("Up"), isPrimary: primary)
    }

    // MARK: Server rows

    func testLaneFilesAreToldApartFromCarriers() {
        XCTAssertEqual(SSHRunner.laneNumber(file: "server-jitsi-2.yaml", provider: "jitsi"), 2)
        XCTAssertEqual(SSHRunner.laneNumber(file: "server-salutejazz-4.yaml", provider: "salutejazz"), 4)
        XCTAssertNil(SSHRunner.laneNumber(file: "server-jitsi.yaml", provider: "jitsi"))
        XCTAssertNil(SSHRunner.laneNumber(file: "server.yaml", provider: "jitsi"))
        XCTAssertNil(SSHRunner.laneNumber(file: "server-jitsi-1.yaml", provider: "jitsi"))
        XCTAssertNil(SSHRunner.laneNumber(file: "server-jitsi-2.yaml", provider: "telemost"))
    }

    func testLanesSplitOffAndBecomeExtraRoomsInOrder() {
        let rows = [row("server.yaml", provider: "jitsi", room: "a", primary: true),
                    row("server-jitsi-3.yaml", provider: "jitsi", room: "c"),
                    row("server-vkcalls.yaml", provider: "vkcalls", room: "v"),
                    row("server-jitsi-2.yaml", provider: "jitsi", room: "b")]
        let (carriers, lanes) = SSHRunner.splitLanes(rows)
        XCTAssertEqual(carriers.map(\.file), ["server.yaml", "server-vkcalls.yaml"])
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(SSHRunner.laneRooms(lanes, carrier: "jitsi"), ["b", "c"])
        XCTAssertEqual(SSHRunner.laneRooms(lanes, carrier: "vkcalls"), [])
    }

    func testAddCarrierPassesTheLane() {
        let options = InstallOptions(carrier: "salutejazz", transport: "datachannel", roomID: "abcd:efgh")
        XCTAssertTrue(SSHRunner.addCarrierEnv(options, baseContainer: "olcrtc-server-x", lane: 3)
            .contains("OLCRTC_LANE=3"))
        XCTAssertFalse(SSHRunner.addCarrierEnv(options, baseContainer: "olcrtc-server-x").contains("OLCRTC_LANE"))
        XCTAssertFalse(SSHRunner.addCarrierEnv(options, baseContainer: "olcrtc-server-x", lane: 1).contains("OLCRTC_LANE"))
        XCTAssertFalse(SSHRunner.addCarrierEnv(options, baseContainer: "olcrtc-server-x", lane: 9).contains("OLCRTC_LANE"))
    }

    func testEveryCallCarrierGetsLanes() {
        // Every call carrier but MTS Link: lanes are extra rooms the app mints
        // on demand, and an MTS Link meeting is made by its owner (see
        // CarrierTransportMatrix.laneCarriers).
        XCTAssertEqual(CarrierTransportMatrix.laneCarriers,
                       Set(CarrierTransportMatrix.carriers).subtracting(["mtslink"]))
    }

    // MARK: Which room next

    func testRoundRobinSkipsRoomsThatAreDown() {
        var policy = LanePolicy(count: 3)
        let now = Date()
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 0)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 1)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 2)
        XCTAssertEqual(policy.pick(isUp: { $0 != 0 }, now: now), 1)
        XCTAssertEqual(policy.pick(isUp: { _ in false }, now: now), 2)   // nothing up: keep rotating
    }

    func testTwoDeadConnectionsBenchARoomForAWhile() {
        var policy = LanePolicy(count: 2)
        let now = Date()
        policy.record(lane: 0, dead: true, now: now)
        policy.record(lane: 0, dead: true, now: now)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 1)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 1)
        // The bench ends, and a good connection clears the count.
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now.addingTimeInterval(LanePolicy.benchSeconds + 1)), 0)
        policy.record(lane: 1, dead: true, now: now)
        policy.record(lane: 1, dead: false, now: now)
        policy.record(lane: 1, dead: true, now: now)
        XCTAssertNil(policy.benchedUntil[1])
    }

    func testALaneWhoseListenerIsGoneIsSetAsideAtOnce() {
        var policy = LanePolicy(count: 2)
        let now = Date()
        policy.setAside(lane: 0, now: now)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 1)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now), 1)
        XCTAssertEqual(policy.pick(isUp: { _ in true }, now: now.addingTimeInterval(LanePolicy.benchSeconds + 1)), 0)
        // Only one lane up, and it is set aside: still better than none.
        policy.setAside(lane: 1, now: now)
        XCTAssertEqual(policy.pick(isUp: { $0 == 1 }, now: now), 1)
        policy.setAside(lane: 7, now: now)   // out of range: ignored
    }

    func testAWaitingOrRefusedLaneConnectionMeansItsListenerIsGone() {
        let refused = NWError.posix(.ECONNREFUSED)
        XCTAssertTrue(LanePolicy.listenerGone(.waiting(refused), bytesBack: 0),
                      "a loopback connect that waits never completes")
        XCTAssertTrue(LanePolicy.listenerGone(.waiting(refused), bytesBack: 900))
        XCTAssertTrue(LanePolicy.listenerGone(.failed(refused), bytesBack: 0))
        XCTAssertFalse(LanePolicy.listenerGone(.failed(refused), bytesBack: 900),
                       "it answered: an ordinary connection end")
        XCTAssertFalse(LanePolicy.listenerGone(.ready, bytesBack: 0))
        XCTAssertFalse(LanePolicy.listenerGone(.preparing, bytesBack: 0))
        XCTAssertFalse(LanePolicy.listenerGone(.cancelled, bytesBack: 0))
    }

    func testADeadRoomLooksLikeAQuickNearlyEmptyAnswer() {
        XCTAssertTrue(LanePolicy.looksDead(bytesBack: 12, duration: 0.4))
        XCTAssertFalse(LanePolicy.looksDead(bytesBack: 12, duration: 30))
        XCTAssertFalse(LanePolicy.looksDead(bytesBack: 4_000, duration: 0.4))
    }

    // MARK: Connection, list, invite

    func testExtraRoomsPersistAndOldRecordsStillDecode() throws {
        var params = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/a", key: "", clientID: "default")
        params.extraRooms = ["https://meet.example.org/b"]
        let again = try JSONDecoder().decode(OlcrtcConnection.self, from: JSONEncoder().encode(params))
        XCTAssertEqual(again.extraRooms, ["https://meet.example.org/b"])
        XCTAssertEqual(again.allRooms, ["https://meet.example.org/a", "https://meet.example.org/b"])
        let old = #"{"carrier":"jitsi","transport":"datachannel","roomID":"r","clientID":"default"}"#
        XCTAssertNil(try JSONDecoder().decode(OlcrtcConnection.self, from: Data(old.utf8)).extraRooms)
    }

    func testListsCarryLanesToTheConnection() throws {
        let key = String(repeating: "ab", count: 32)
        let sub = OlcrtcSubscription.parse("""
        olcrtc://salutejazz?datachannel@abcd12:efgh3456#\(key)
        ##lanes: wxyz12:mnop3456, qrst12:uvwx3456
        """)
        XCTAssertEqual(sub.entries.first?.lanes, ["wxyz12:mnop3456", "qrst12:uvwx3456"])
        let diff = ConnectionStore.diffSubscription(sub, source: "olcrtc-sub://h/s", group: "g", existing: [])
        guard case .olcrtc(let p)? = diff.toAdd.first?.details else { return XCTFail("no connection") }
        XCTAssertEqual(p.extraRooms, ["wxyz12:mnop3456", "qrst12:uvwx3456"])
    }

    func testInvitesCarryLanes() throws {
        let key = String(repeating: "ab", count: 32)
        var params = OlcrtcConnection(from: try OlcrtcURI.parse("olcrtc://jitsi?datachannel@https://m.example.org/a#\(key)"))
        params.extraRooms = ["https://m.example.org/b"]
        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams",
                                                    records: [ConnectionRecord(name: "ams · Jitsi", details: .olcrtc(params))]))
        XCTAssertTrue(body.contains("##lanes: https://m.example.org/b"), body)
        XCTAssertEqual(OlcrtcSubscription.parse(body).entries.first?.lanes, ["https://m.example.org/b"])
    }
}
