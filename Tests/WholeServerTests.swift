import XCTest
@testable import olcrtc_ios

// The whole-server connection (ServerBundle): how a server's protocols and
// rooms become one connection, how it travels in a list or an invite, what the
// main screen folds under it, and the bond endpoint's server script. The
// engine's runtimes, the bonding itself (gomobile/bond, Go-tested) and the SSH
// deployment are integration-only: on a VPS two SaluteJazz rooms carried one
// download at about twice the speed of one, and it finished when a room died.

@MainActor
final class WholeServerTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)
    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    private func proto(_ carrier: String, _ transport: String, _ room: String,
                       extra: [String]? = nil) -> OlcrtcConnection {
        var p = OlcrtcConnection(carrier: carrier, transport: transport, roomID: room, key: key, clientID: "default")
        p.extraRooms = extra
        return p
    }

    // MARK: Composition

    func testProtocolsAndRoomsBecomeOneConnection() throws {
        var telemost = proto("telemost", "datachannel", "123", extra: ["456"])
        telemost.roomCreatedAt = Date()
        var vk = proto("vkcalls", "vp8channel", "https://vk.com/call/join/abc")
        vk.vp8FPS = 25
        vk.vp8BatchSize = 4
        var wb = proto("wbstream", "vp8channel", "room-wb")
        wb.wbToken = "token"
        let bundle = try XCTUnwrap(ServerBundle.params(protocols: [telemost, vk, wb], bond: "203.0.113.7:30000"))
        XCTAssertTrue(bundle.isBundle)
        XCTAssertEqual(bundle.lanes, [
            OlcrtcLane(carrier: "telemost", transport: "datachannel", roomID: "123"),
            OlcrtcLane(carrier: "telemost", transport: "datachannel", roomID: "456"),
            OlcrtcLane(carrier: "vkcalls", transport: "vp8channel", roomID: "https://vk.com/call/join/abc"),
            OlcrtcLane(carrier: "wbstream", transport: "vp8channel", roomID: "room-wb"),
        ])
        XCTAssertEqual(bundle.bond, "203.0.113.7:30000")
        XCTAssertEqual(bundle.vp8FPS, 25)
        XCTAssertEqual(bundle.vp8BatchSize, 4)
        XCTAssertNil(bundle.roomCreatedAt, "the renewal clock stays with the protocol records")
        // The WB account token reaches the wbstream lane and no other.
        XCTAssertEqual(OlcrtcEngine.providerToken(bundle, carrier: "wbstream"), "token")
        XCTAssertEqual(OlcrtcEngine.providerToken(bundle, carrier: "vkcalls"), "")
        XCTAssertEqual(OlcrtcEngine.providerToken(bundle), "")
    }

    func testOneProtocolOrAMissingKeyMakesNoBundle() {
        XCTAssertNil(ServerBundle.params(
            protocols: [proto("salutejazz", "datachannel", "ab12:cd34", extra: ["ef56:gh78"])], bond: nil))
        var keyless = proto("jitsi", "datachannel", "https://m.example.org/x")
        keyless.key = ""
        XCTAssertNil(ServerBundle.params(protocols: [proto("telemost", "datachannel", "1"), keyless], bond: nil))
        XCTAssertNil(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1"), proto("telemost", "datachannel", "1")], bond: nil),
            "the same room twice is one lane")
    }

    func testTheRoomsOfOneProtocolAreBondedToo() {
        XCTAssertNil(ServerBundle.bond(for: proto("salutejazz", "datachannel", "a:b"), endpoint: "h:1"))
        XCTAssertEqual(ServerBundle.bond(for: proto("salutejazz", "datachannel", "a:b", extra: ["c:d"]),
                                         endpoint: "h:1"), "h:1")
    }

    func testEndpointsSplitAndBracketIPv6() {
        var host = ServerHost(label: "ams", host: "203.0.113.7")
        XCTAssertNil(ServerBundle.endpoint(host: host))
        host.bondPort = 30000
        XCTAssertEqual(ServerBundle.endpoint(host: host), "203.0.113.7:30000")
        host.host = "2001:db8::1"
        XCTAssertEqual(ServerBundle.endpoint(host: host), "[2001:db8::1]:30000")
        XCTAssertEqual(ServerBundle.split(endpoint: "[2001:db8::1]:30000")?.host, "2001:db8::1")
        XCTAssertEqual(ServerBundle.split(endpoint: "vps.example.org:443")?.port, 443)
        XCTAssertNil(ServerBundle.split(endpoint: "vps.example.org"))
        XCTAssertNil(ServerBundle.split(endpoint: ":443"))
        XCTAssertNil(ServerBundle.split(endpoint: "vps.example.org:70000"))
    }

    // MARK: Staying up

    func testAStuckRoomDoesNotRestartASessionOverSeveralRooms() throws {
        let single = ConnectionRecord(name: "one", details: .olcrtc(proto("jitsi", "datachannel", "j")))
        let rooms = ConnectionRecord(name: "rooms", details: .olcrtc(proto("telemost", "datachannel", "1", extra: ["2"])))
        let bundle = try XCTUnwrap(ServerBundle.params(protocols: [proto("jitsi", "datachannel", "j"),
                                                                   proto("salutejazz", "datachannel", "a:b")],
                                                       bond: "203.0.113.7:30000"))
        XCTAssertFalse(TunnelManager.ridesSeveralLanes(single))
        XCTAssertFalse(TunnelManager.ridesSeveralLanes(nil))
        XCTAssertTrue(TunnelManager.ridesSeveralLanes(rooms))
        XCTAssertTrue(TunnelManager.ridesSeveralLanes(ConnectionRecord(name: "server", details: .olcrtc(bundle))))
    }

    // MARK: The main screen

    func testTheBundleLeadsItsGroupAndFoldsTheProtocolsItJoins() throws {
        let telemost = ConnectionRecord(name: "ams · telemost", details: .olcrtc(proto("telemost", "datachannel", "1")))
        let vk = ConnectionRecord(name: "ams · vkcalls", details: .olcrtc(proto("vkcalls", "vp8channel", "v")))
        var other = proto("jitsi", "datachannel", "j")
        other.key = String(repeating: "cd", count: 32)
        let elsewhere = ConnectionRecord(name: "fra", details: .olcrtc(other))
        let params = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1"), proto("vkcalls", "vp8channel", "v")], bond: nil))
        let bundle = ConnectionRecord(name: "ams", details: .olcrtc(params))
        XCTAssertEqual(ServerBundle.coveredIDs(in: [telemost, vk, elsewhere, bundle]), [telemost.id, vk.id])

        XCTAssertTrue(bundle.isBundle)
        XCTAssertFalse(telemost.isBundle)
        XCTAssertEqual(ConnectionNaming.service(bundle.details), "Whole server")
        XCTAssertEqual(ConnectionNaming.transport(bundle.details), "Yandex Telemost + VK Calls · 2 rooms")
        XCTAssertEqual(ConnectionNaming.host(bundle), "ams")
    }

    func testTheGroupListsTheBundleFirst() throws {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "WholeServerTests-\(UUID().uuidString)")!)
        let telemost = ConnectionRecord(name: "ams · telemost", details: .olcrtc(proto("telemost", "datachannel", "1")))
        let params = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1"), proto("vkcalls", "vp8channel", "v")], bond: nil))
        let bundle = ConnectionRecord(name: "ams", details: .olcrtc(params))
        store.connections = [telemost, bundle]
        defer {
            for id in [telemost.id, bundle.id] { ConnectionSecretStore.remove(connectionID: id) }
        }
        XCTAssertEqual(store.grouped().first?.items.map(\.id), [bundle.id, telemost.id])
    }

    // MARK: Lists and invites

    func testInvitesAndListsCarryTheWholeServer() throws {
        let params = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1", extra: ["2"]),
                        proto("salutejazz", "datachannel", "ab12:cd34")],
            bond: "203.0.113.7:30000"))
        let record = ConnectionRecord(name: "ams", details: .olcrtc(params))
        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [record]))
        XCTAssertTrue(body.contains("##with: salutejazz?datachannel@ab12:cd34"), body)
        XCTAssertTrue(body.contains("##bond: 203.0.113.7:30000"), body)

        let sub = OlcrtcSubscription.parse(body)
        let entry = try XCTUnwrap(sub.entries.first)
        XCTAssertEqual(entry.with, [OlcrtcLane(carrier: "salutejazz", transport: "datachannel", roomID: "ab12:cd34")])
        XCTAssertEqual(entry.bond, "203.0.113.7:30000")
        let diff = ConnectionStore.diffSubscription(sub, source: "olcrtc-sub://h/s", group: "g", existing: [])
        guard case .olcrtc(let imported)? = diff.toAdd.first?.details else { return XCTFail("no connection") }
        XCTAssertTrue(imported.isBundle)
        XCTAssertEqual(imported.lanes.count, 3)
        XCTAssertEqual(imported.bond, "203.0.113.7:30000")
    }

    func testABundleAndItsFirstProtocolStayTwoConnections() {
        // A plain list, no ##id: the two lines share the first lane.
        let sub = OlcrtcSubscription.parse("""
        olcrtc://telemost?datachannel@123#\(key)
        ##name: ams · telemost
        olcrtc://telemost?datachannel@123#\(key)
        ##name: ams
        ##with: vkcalls?vp8channel@https://vk.com/call/join/abc, bad-lane
        ##bond: not-an-endpoint
        """)
        XCTAssertEqual(sub.entries.count, 2)
        XCTAssertNotEqual(sub.entries[0].nodeKey, sub.entries[1].nodeKey)
        XCTAssertEqual(sub.entries[1].with.map(\.carrier), ["vkcalls"], "a malformed lane is skipped")
        XCTAssertNil(sub.entries[1].bond, "a malformed endpoint is dropped")
        let diff = ConnectionStore.diffSubscription(sub, source: "olcrtc-sub://h/s", group: "g", existing: [])
        XCTAssertEqual(diff.toAdd.count, 2)
    }

    func testStoredRecordsAndHostsDecodeWithAndWithoutTheNewFields() throws {
        let old = #"{"carrier":"jitsi","transport":"datachannel","roomID":"r","clientID":"default"}"#
        let decoded = try JSONDecoder().decode(OlcrtcConnection.self, from: Data(old.utf8))
        XCTAssertNil(decoded.bundleLanes)
        XCTAssertNil(decoded.bond)
        XCTAssertFalse(decoded.isBundle)

        var p = proto("telemost", "datachannel", "1")
        p.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel", roomID: "v")]
        p.bond = "h:1"
        let again = try JSONDecoder().decode(OlcrtcConnection.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(again.bundleLanes, p.bundleLanes)
        XCTAssertEqual(again.bond, "h:1")

        var host = ServerHost(label: "ams", host: "h")
        host.bundleConnectionID = UUID()
        host.bondPort = 30000
        host.bondVersion = "0123456789abcdef"
        XCTAssertEqual(try JSONDecoder().decode(ServerHost.self, from: JSONEncoder().encode(host)), host)
    }

    func testTheHostLinksItsWholeServerRecordFirst() {
        var host = ServerHost(label: "ams", host: "h")
        let primary = UUID(), bundle = UUID()
        host.lastConnectionID = primary
        host.bundleConnectionID = bundle
        XCTAssertEqual(host.linkedConnectionIDs, [bundle, primary])
        XCTAssertTrue(host.links(bundle))
    }

    func testABundleRidesTheRoomsItJoins() throws {
        let bundle = try XCTUnwrap(ServerBundle.params(
            protocols: [proto("telemost", "datachannel", "1", extra: ["2"]), proto("vkcalls", "vp8channel", "v")],
            bond: nil))
        XCTAssertTrue(ServerBundle.rides(bundle, carrier: "telemost", roomID: "2"))
        XCTAssertFalse(ServerBundle.rides(bundle, carrier: "telemost", roomID: "9"))
    }

    // MARK: The server side

    func testTheBondScriptBuildsOnceAndListensOnTheHostNetwork() {
        let sources = [(path: "bond/protocol.go", text: "package bond\n"),
                       (path: "bond/cmd/olcos-bond/main.go", text: "package main\n")]
        let script = SSHRunner.bondEnsureScript(port: 31000, version: "v1", sources: sources, dns: "1.1.1.1:53")
        XCTAssertTrue(script.contains("--network host"))
        XCTAssertTrue(script.contains("--network none"), "the build needs no network")
        XCTAssertTrue(script.contains("-v \"$KEY:/key:ro,Z\""), "the key is mounted, never copied")
        XCTAssertTrue(script.contains("PORT=31000"))
        XCTAssertTrue(script.contains(AppConstants.serverGoImage))
        XCTAssertTrue(script.contains("!= \"v1\""), "a new version rebuilds")
        XCTAssertTrue(script.contains(Data("package bond\n".utf8).base64EncodedString()))
        XCTAssertTrue(script.contains("-dns \"1.1.1.1:53\""))
        XCTAssertTrue(script.contains("OLCOS_BOND_ERROR=port_busy"))
    }

    func testTheBondScriptOutputIsRead() {
        XCTAssertEqual(SSHRunner.parseBondOutput("noise\nOLCOS_BOND_PORT=31000\n"),
                       SSHRunner.BondResult(port: 31000, error: nil))
        XCTAssertEqual(SSHRunner.parseBondOutput("OLCOS_BOND_ERROR=port_busy").error, "port_busy")
        XCTAssertEqual(SSHRunner.parseBondOutput("OLCOS_BOND_ERROR=").error, "unknown")
    }

    func testTheAppCarriesTheBondSources() throws {
        let sources = try SSHRunner.bondSources()
        XCTAssertEqual(sources.map(\.path), SSHRunner.bondSourceFiles)
        XCTAssertTrue(sources.allSatisfy { !$0.text.isEmpty })
        XCTAssertTrue(sources.last?.text.contains("bond.Serve(") ?? false)
        XCTAssertEqual(SSHRunner.bondVersion(sources).count, 16)
    }

    func testUninstallTakesTheBondEndpointBeforeTheImage() throws {
        for script in [SSHRunner.uninstallScript(containerName: "olcrtc-server-abc"),
                       SSHRunner.deepUninstallScript(containerName: "olcrtc-server-abc", removeImage: true)] {
            XCTAssertTrue(script.contains("podman rm -f olcos-bond"))
            XCTAssertTrue(script.contains("rm -rf /opt/olcos-bond"))
        }
        let deep = SSHRunner.deepUninstallScript(containerName: nil, removeImage: true)
        let bond = try XCTUnwrap(deep.range(of: "podman rm -f olcos-bond"))
        let rmi = try XCTUnwrap(deep.range(of: "podman rmi"))
        XCTAssertLessThan(bond.lowerBound, rmi.lowerBound, "the endpoint runs from the image it would pin")
    }
}
