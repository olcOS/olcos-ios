import XCTest
@testable import olcrtc_ios

/// The key the bond groups lanes by (olcos-core/mobile/bond SetLaneGroup): rooms on one
/// conference host fail together, so the bond takes its backup off that host.
/// Pure mapping only — that the bond then prefers another group is the bond's
/// own tests' business.
final class LaneGroupTests: XCTestCase {

    func testTwoRoomsOnOneHostShareAGroup() {
        let a = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/room-a")
        let b = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/room-b")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "jitsi:meet.example.org")
    }

    func testTheSchemeDoesNotSplitAHost() {
        let secure = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/a")
        let plain = LaneGroup.key(carrier: "jitsi", room: "http://meet.example.org/b")
        XCTAssertEqual(secure, plain)
    }

    func testTwoHostsAreTwoGroups() {
        let one = LaneGroup.key(carrier: "jitsi", room: "https://one.example.org/a")
        let other = LaneGroup.key(carrier: "jitsi", room: "https://other.example.org/b")
        XCTAssertNotEqual(one, other)
        XCTAssertEqual(LaneGroup.key(carrier: "jitsi", room: "https://OTHER.example.org/x"), other,
                       "a host is the same whatever its case")
    }

    func testAPathPrefixIsPartOfTheHost() {
        // A deployment behind a path-mounted proxy: the core keeps the prefix
        // as part of the host, so two prefixes are two deployments.
        let mounted = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/jitsi/a")
        let root = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/b")
        XCTAssertNotEqual(mounted, root)
        XCTAssertEqual(LaneGroup.key(carrier: "jitsi", room: "meet.example.org/jitsi/b"),
                       "jitsi:meet.example.org/jitsi",
                       "a room URL without a scheme names the same host")
    }

    func testARoomWithoutAHostIsItsOwnGroup() {
        for room in ["room-id", "", "   ", "https://meet.example.org", "https://", "/room"] {
            XCTAssertEqual(LaneGroup.key(carrier: "jitsi", room: room), "",
                           "\(room.debugDescription) names no host")
        }
        XCTAssertNil(LaneGroup.host(of: "room-id"))
    }

    func testTheCarrierKeepsTwoHostsApart() {
        let jitsi = LaneGroup.key(carrier: "jitsi", room: "https://meet.example.org/a")
        let other = LaneGroup.key(carrier: "vkcalls", room: "https://meet.example.org/a")
        XCTAssertNotEqual(jitsi, other)
    }

    func testWhitespaceAroundARoomIsIgnored() {
        XCTAssertEqual(LaneGroup.key(carrier: "jitsi", room: "  https://meet.example.org/a  "),
                       "jitsi:meet.example.org")
    }
}
