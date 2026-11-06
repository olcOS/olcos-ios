import XCTest
@testable import olcrtc_ios

// #vpn: TunnelManager.connectionState(forVPNStatus:hasRecord:reason:) is the
// pure NEVPNStatus → ConnectionState bridge for VPN mode (nil = leave the
// state machine untouched). Every VPNController.Status × hasRecord combination
// is pinned here, mirroring NetworkPathDecisionTests for `pathDecision`.
//
// Contract under test:
//   .connecting    → .connecting                (either way)
//   .connected     → .connected                 (either way)
//   .reasserting   → .connecting                (system tunnel self-recovering)
//   .disconnecting → nil                        (transitional — hold state)
//   .invalid       → nil                        (no information — hold state)
//   .disconnected  → hasRecord ? .failed(reason ?? L10n.vpnDisconnected)
//                              : .disconnected
//
// A user-initiated disconnect never reaches this mapping at all —
// `disconnect()` restores activeMode to .proxy before the observer's late
// emissions arrive, so only an UNEXPECTED drop can produce the .failed here.

final class VPNStatusMappingTests: XCTestCase {

    private func map(_ status: VPNController.Status,
                     hasRecord: Bool,
                     reason: String? = nil) -> ConnectionState? {
        TunnelManager.connectionState(forVPNStatus: status,
                                      hasRecord: hasRecord,
                                      reason: reason)
    }

    // MARK: Live-session statuses (record irrelevant)

    func testConnectingMapsToConnecting() {
        XCTAssertEqual(map(.connecting, hasRecord: true),  .connecting)
        XCTAssertEqual(map(.connecting, hasRecord: false), .connecting)
    }

    func testConnectedMapsToConnected() {
        XCTAssertEqual(map(.connected, hasRecord: true),  .connected)
        XCTAssertEqual(map(.connected, hasRecord: false), .connected)
    }

    func testReassertingMapsToConnecting() {
        // The system tunnel reconnects on its own after a path change — the
        // closest in-app notion is "connecting"; no in-app machinery runs.
        XCTAssertEqual(map(.reasserting, hasRecord: true),  .connecting)
        XCTAssertEqual(map(.reasserting, hasRecord: false), .connecting)
    }

    // MARK: Transitional / no-information statuses → no state change

    func testDisconnectingIsANoOp() {
        XCTAssertNil(map(.disconnecting, hasRecord: true))
        XCTAssertNil(map(.disconnecting, hasRecord: false))
    }

    func testInvalidIsANoOp() {
        XCTAssertNil(map(.invalid, hasRecord: true))
        XCTAssertNil(map(.invalid, hasRecord: false))
    }

    // MARK: Disconnected — the only status where hasRecord changes the outcome

    func testDisconnectedWithoutRecordIsIdleDisconnected() {
        XCTAssertEqual(map(.disconnected, hasRecord: false), .disconnected)
        // The reason is irrelevant without a record — still a plain disconnect.
        XCTAssertEqual(map(.disconnected, hasRecord: false, reason: "boom"),
                       .disconnected)
    }

    func testDisconnectedWithRecordIsAFailureCarryingTheProviderReason() {
        XCTAssertEqual(map(.disconnected, hasRecord: true, reason: "TURN relay rejected"),
                       .failed("TURN relay rejected"))
    }

    func testDisconnectedWithRecordFallsBackToGenericReason() {
        XCTAssertEqual(map(.disconnected, hasRecord: true, reason: nil),
                       .failed(L10n.vpnDisconnected.localized()))
    }

    // MARK: The phone's network (the app's own path monitor)

    func testOfflineAnUpOrRejoiningTunnelWaitsForTheNetwork() {
        // The extension holds while the network is gone and the system reads
        // "reasserting": that is not a connect in progress.
        XCTAssertEqual(TunnelManager.vpnState(.connecting, networkUp: false), .waitingForNetwork)
        XCTAssertEqual(TunnelManager.vpnState(.connected, networkUp: false), .waitingForNetwork)
        XCTAssertEqual(TunnelManager.vpnState(.connecting, networkUp: true), .connecting)
        XCTAssertEqual(TunnelManager.vpnState(.connected, networkUp: true), .connected)
        XCTAssertEqual(TunnelManager.vpnState(.connected, networkUp: nil), .connected,
                       "no reading of the network yet: the tunnel's word stands")
        XCTAssertEqual(TunnelManager.vpnState(.failed("boom"), networkUp: false), .failed("boom"))
        XCTAssertEqual(TunnelManager.vpnState(.disconnected, networkUp: false), .disconnected)
        XCTAssertEqual(TunnelManager.vpnState(.waitingForNetwork, networkUp: true), .waitingForNetwork)
    }

    func testARejoiningTunnelReadsReconnecting() {
        XCTAssertTrue(TunnelManager.showsReconnecting(pendingRecovery: false, mode: .vpn, vpnStatus: .reasserting))
        XCTAssertFalse(TunnelManager.showsReconnecting(pendingRecovery: false, mode: .vpn, vpnStatus: .connecting),
                       "a first connect is a connect")
        XCTAssertTrue(TunnelManager.showsReconnecting(pendingRecovery: true, mode: .proxy, vpnStatus: .disconnected))
        XCTAssertFalse(TunnelManager.showsReconnecting(pendingRecovery: false, mode: .proxy, vpnStatus: .reasserting),
                       "in proxy mode only the app's own recovery counts")
    }
}
