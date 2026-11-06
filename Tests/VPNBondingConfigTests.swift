import XCTest
@testable import olcrtc_ios

// VPN bonding (Settings → VPN, on by default): which rooms of a whole-server
// connection the packet tunnel is handed, and that they survive the trip
// through the system's VPN preferences. The extension's own start is
// integration-only (no Network Extension in the simulator test host).

final class VPNBondingConfigTests: XCTestCase {

    private let key = String(repeating: "a", count: 64)

    private func wholeServer() throws -> OlcrtcConnection {
        func proto(_ carrier: String, _ transport: String, _ room: String) -> OlcrtcConnection {
            OlcrtcConnection(carrier: carrier, transport: transport, roomID: room, key: key, clientID: "test")
        }
        return try XCTUnwrap(ServerBundle.params(protocols: [
            proto("jitsi", "datachannel", "https://meet.example.org/a"),
            proto("salutejazz", "datachannel", "abc:def"),
            proto("telemost", "videochannel", "1111"),
            proto("vkcalls", "vp8channel", "https://vk.com/call/join/x"),
            proto("wbstream", "datachannel", "room-w"),
        ], bond: "203.0.113.7:34567"))
    }

    /// A fresh install (and anyone who never touched the switch) bonds a
    /// whole-server connection in VPN mode; the switch is the escape hatch.
    func testBondingIsOnByDefault() {
        XCTAssertTrue(SettingsStore.Defaults.vpnBonding)
    }

    /// The config builder bonds only when it is told to, which is what the
    /// switch decides (TunnelManager passes `SettingsStore.vpnBonding`).
    func testNotAskedToBondTheVPNCarriesOneRoom() throws {
        let config = VPNConfig(from: try wholeServer(), dns: "1.1.1.1:53", timeoutMs: 1_000)
        XCTAssertFalse(config.isBonded)
        XCTAssertEqual(config.bond, "")
    }

    func testBondedTheVPNGetsUpToThreeRoomsAndNoVideo() throws {
        let config = VPNConfig(from: try wholeServer(), dns: "1.1.1.1:53", timeoutMs: 1_000, bonded: true)
        XCTAssertTrue(config.isBonded)
        XCTAssertEqual(config.bond, "203.0.113.7:34567")
        XCTAssertEqual(config.lanes.count, VPNConfig.maxBondedLanes)
        XCTAssertFalse(config.lanes.contains { $0.transport == "videochannel" },
                       "the video transport cannot fit the extension")
        let first = try XCTUnwrap(config.lanes.first)
        XCTAssertEqual(first.carrier, "jitsi")
        XCTAssertEqual(first.transport, "datachannel")
        XCTAssertEqual(first.room, "https://meet.example.org/a")
        // Each lane carries its own vp8 numbers (the person's here: no MTS Link room among them).
        XCTAssertEqual(first.vp8FPS, SettingsStore.Defaults.vp8FPS)
        XCTAssertEqual(first.vp8Batch, SettingsStore.Defaults.vp8BatchSize)
    }

    func testTheLanesSurviveTheSystemPreferences() throws {
        let config = VPNConfig(from: try wholeServer(), dns: "1.1.1.1:53", timeoutMs: 1_000, bonded: true)
        let back = try XCTUnwrap(VPNConfig(providerConfiguration: config.providerConfiguration()))
        XCTAssertEqual(back.lanes, config.lanes)
        XCTAssertEqual(back.bond, config.bond)
        var legacy = config.providerConfiguration()
        legacy.removeValue(forKey: "lanesJSON")
        legacy.removeValue(forKey: "bond")
        XCTAssertEqual(VPNConfig(providerConfiguration: legacy)?.isBonded, false,
                       "a profile saved before VPN bonding carries one room")
    }

    /// Three Jitsi rooms and one SaluteJazz room: the VPN takes one room of each
    /// service first, so SaluteJazz is not crowded out by the third Jitsi room.
    func testBondedRoomsAreTakenOneServiceAtATime() {
        let lanes = [
            OlcrtcLane(carrier: "jitsi", transport: "datachannel", roomID: "j1"),
            OlcrtcLane(carrier: "jitsi", transport: "datachannel", roomID: "j2"),
            OlcrtcLane(carrier: "jitsi", transport: "datachannel", roomID: "j3"),
            OlcrtcLane(carrier: "salutejazz", transport: "datachannel", roomID: "s1"),
        ]
        XCTAssertEqual(VPNConfig.bondedLanes(lanes).map(\.roomID), ["j1", "s1", "j2"])
        XCTAssertEqual(VPNConfig.bondedLanes(Array(lanes.prefix(2))).map(\.roomID), ["j1", "j2"])
    }

    func testOneRoomIsNeverBonded() {
        let single = OlcrtcConnection(carrier: "jitsi", transport: "datachannel", roomID: "r", key: key, clientID: "t")
        XCTAssertFalse(VPNConfig(from: single, dns: "1.1.1.1:53", timeoutMs: 1_000, bonded: true).isBonded)
    }
}
