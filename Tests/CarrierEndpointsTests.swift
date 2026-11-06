import XCTest
@testable import olcrtc_ios

// #328: pins the carrier-base-host derivation used by the proxy-loop exclusion
// card. Only the params-derivable host is tested here (no network) — the live
// DNS resolve pass is exercised at runtime, not in unit tests, and the core
// exposes no ICE endpoints (Mobile.objc.h), so this host is the only thing we
// can name from the connection alone.
final class CarrierEndpointsTests: XCTestCase {

    func testJitsiRoomURLYieldsHost() {
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "https://meet1.arbitr.ru/myroom"),
                       "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "https://meet.jit.si/room#frag"),
                       "meet.jit.si")
    }

    func testBareHostAndHostPathForms() {
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru/myroom"), "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru:8443/myroom"), "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru"), "meet1.arbitr.ru")
    }

    func testOpaqueRoomIDHasNoHost() {
        // telemost / wbstream opaque room IDs are not hosts — nothing to derive.
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "myroom"))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "abc-123-xyz"))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: ""))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "   "))
    }

    func testBaseHostUsesRoomID() {
        let jitsi = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                     roomID: "https://meet1.arbitr.ru/r", key: "", clientID: "default")
        XCTAssertEqual(CarrierEndpoints.baseHost(for: jitsi), "meet1.arbitr.ru")

        let telemost = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                        roomID: "opaque-room-id", key: "", clientID: "default")
        XCTAssertNil(CarrierEndpoints.baseHost(for: telemost))
    }

    // MARK: A fresh Jitsi room
    //
    // The room a new-room tap and a scheduled rotation both make: on the
    // service the old room was on, named the way the server's own install
    // names one.

    func testAFreshJitsiRoomStaysOnTheServiceOfTheOldOne() {
        let prefix = "https://meet1.arbitr.ru/olcrtc-"
        let room = CarrierEndpoints.freshJitsiRoom(near: "https://meet1.arbitr.ru/olcrtc-abcd1234")
        XCTAssertTrue(room.hasPrefix(prefix), room)
        let name = String(room.dropFirst(prefix.count))
        XCTAssertEqual(name.count, 8)
        XCTAssertTrue(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }, name)
        // The old room may have been written without a scheme.
        XCTAssertTrue(CarrierEndpoints.freshJitsiRoom(near: "meet1.arbitr.ru/x").hasPrefix(prefix))
    }

    func testAFreshJitsiRoomIsNeverTheSameTwice() {
        let rooms = Set((0..<20).map { _ in CarrierEndpoints.freshJitsiRoom(near: "meet1.arbitr.ru/x") })
        XCTAssertEqual(rooms.count, 20)
    }

    func testAFreshJitsiRoomOnARoomWithoutAServiceUsesTheDefaultOne() {
        let prefix = AppConstants.defaultJitsiBaseURL + "/olcrtc-"
        XCTAssertTrue(CarrierEndpoints.freshJitsiRoom(near: "myroom").hasPrefix(prefix))
        XCTAssertTrue(CarrierEndpoints.freshJitsiRoom(near: "").hasPrefix(prefix))
    }
}
