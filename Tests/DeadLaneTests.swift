import XCTest
@testable import olcrtc_ios

// A lane of a live whole-server session that stays out of its room: the lane
// watch keeps rejoining it, but on a room the server may have left. Past the
// limit the app re-reads where the connection's rooms are (its list, its
// server) and, when that lane's room moved, joins the new one. The watch and
// the decision are pure; the re-read itself (SSH, a list download) and the
// reconnect are integration-only.
final class DeadLaneTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)

    // MARK: The watch

    func testALaneIsNamedOnceItHasBeenOutOfItsRoomForTheLimit() {
        var watch = DeadLaneWatch()
        XCTAssertEqual(watch.deadLanes(up: [true, false, true], now: 0), [])
        XCTAssertEqual(watch.deadLanes(up: [true, false, true], now: DeadLaneWatch.limit - 1), [])
        XCTAssertEqual(watch.deadLanes(up: [true, false, true], now: DeadLaneWatch.limit), [1])
        XCTAssertEqual(watch.deadLanes(up: [true, false, true], now: DeadLaneWatch.limit + 30), [],
                       "named once, not on every look")
        XCTAssertEqual(watch.deadLanes(up: [true, false, true], now: DeadLaneWatch.limit + DeadLaneWatch.again),
                       [1], "and again after a while, in case the room moves later")
    }

    func testALaneThatComesBackStartsOver() {
        var watch = DeadLaneWatch()
        _ = watch.deadLanes(up: [false, true], now: 0)
        _ = watch.deadLanes(up: [true, true], now: DeadLaneWatch.limit - 5)
        XCTAssertEqual(watch.deadLanes(up: [false, true], now: DeadLaneWatch.limit), [])
        XCTAssertEqual(watch.deadLanes(up: [false, true], now: 2 * DeadLaneWatch.limit), [0])
    }

    func testAnotherSetOfLanesStartsOver() {
        var watch = DeadLaneWatch()
        _ = watch.deadLanes(up: [false, true], now: 0)
        XCTAssertEqual(watch.deadLanes(up: [false, true, true], now: DeadLaneWatch.limit), [])
    }

    func testTheLimitIsTheLaneSilenceLimit() {
        XCTAssertEqual(DeadLaneWatch.limit, LaneSilenceWatch.limit)
        XCTAssertGreaterThan(DeadLaneWatch.again, DeadLaneWatch.limit)
    }

    // MARK: The decision

    private func proto(_ carrier: String, _ transport: String, _ room: String) -> OlcrtcConnection {
        OlcrtcConnection(carrier: carrier, transport: transport, roomID: room, key: key, clientID: "default")
    }

    func testOnlyAMovedRoomRejoins() throws {
        let live = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("jitsi", "datachannel", "https://meet.example/a"),
                        proto("salutejazz", "datachannel", "ab12:cd34")], bond: nil))
        let moved = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("jitsi", "datachannel", "https://meet.example/a"),
                        proto("salutejazz", "datachannel", "ef56:gh78")], bond: nil))
        XCTAssertTrue(TunnelManager.deadLaneMoved(live: live, fresh: moved, lane: 1))
        XCTAssertFalse(TunnelManager.deadLaneMoved(live: live, fresh: moved, lane: 0),
                       "the dead lane's room is still the server's: nothing to rejoin")
        XCTAssertFalse(TunnelManager.deadLaneMoved(live: live, fresh: live, lane: 1))
        XCTAssertFalse(TunnelManager.deadLaneMoved(live: live, fresh: moved, lane: 5))
    }

    // MARK: Following the server's rooms

    @MainActor
    func testARoomTheServerChangedIsTakenIntoItsRecord() {
        let jazz = ConnectionRecord(name: "srv · SaluteJazz", details: .olcrtc(proto("salutejazz", "datachannel", "ab12:cd34")))
        let jitsi = ConnectionRecord(name: "srv · Jitsi", details: .olcrtc(proto("jitsi", "datachannel", "https://meet.example/a")))
        var host = ServerHost(label: "srv", host: "203.0.113.9")
        host.lastConnectionID = jitsi.id
        host.extraConnectionIDs = [jazz.id]
        let rows = [
            SSHRunner.CarrierInfo(file: "server.yaml", provider: "jitsi", transport: "datachannel",
                                  room: "https://meet.example/a", container: "olcrtc-server-test",
                                  status: .running("Up 1 hour"), isPrimary: true),
            SSHRunner.CarrierInfo(file: "server-salutejazz.yaml", provider: "salutejazz", transport: "datachannel",
                                  room: "ef56:gh78", container: "olcrtc-server-test-salutejazz",
                                  status: .running("Up 1 hour"), isPrimary: false),
        ]
        let changed = ServersView.followedServerRooms(host: host, carriers: rows, records: [jitsi, jazz])
        XCTAssertEqual(changed.map(\.id), [jazz.id])
        guard case .olcrtc(let p)? = changed.first?.details else { return XCTFail("no record") }
        XCTAssertEqual(p.roomID, "ef56:gh78")
        XCTAssertNil(p.roomCreatedAt)
    }
}
