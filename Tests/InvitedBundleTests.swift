import XCTest
@testable import olcrtc_ios

// A phone invited with server access keeps the server as an agent-only host,
// and the whole-server connection comes from the invite's list with the bond
// endpoint the owner's phone deployed (`##bond`). This phone never deploys
// one there, so the list's record is the truth: the host names it by its own
// marker (`isBundle`), whatever order the list is in, and BundleSync leaves
// the records of such a host alone. Rewriting them dropped the bond (the lanes
// then took turns) and, with the whole-server record last in the list, turned
// a protocol record with extra rooms into a whole-server one.
@MainActor
final class InvitedBundleTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)
    private let source = "olcrtc-sub://198.51.100.7:8443/0123456789abcdef0123456789abcdef?enc=v1"
    private let bond = "198.51.100.7:4443"

    private func body(wholeServerLast: Bool) -> String {
        let whole = """
        olcrtc://telemost?datachannel@10000000000001#\(key)
        ##name: Whole server
        ##lanes: 10000000000002
        ##with: salutejazz?datachannel@ab12:cd34,vkcalls?vp8channel@https://vk.com/call/join/fakeroom
        ##bond: \(bond)
        """
        let telemost = """
        olcrtc://telemost?datachannel@10000000000001#\(key)
        ##name: Srv · Telemost
        ##lanes: 10000000000002
        ##bond: \(bond)
        """
        let jazz = """
        olcrtc://salutejazz?datachannel@ab12:cd34#\(key)
        ##name: Srv · SaluteJazz
        """
        let vk = """
        olcrtc://vkcalls?vp8channel@https://vk.com/call/join/fakeroom#\(key)
        ##name: Srv · VK
        """
        let protocols = [telemost, jazz, vk]
        return (wholeServerLast ? protocols + [whole] : [whole] + protocols).joined(separator: "\n")
    }

    private func records(wholeServerLast: Bool) -> [ConnectionRecord] {
        let sub = OlcrtcSubscription.parse(body(wholeServerLast: wholeServerLast))
        return ConnectionStore.diffSubscription(sub, source: source, group: "My server", existing: []).toAdd
    }

    private func params(_ record: ConnectionRecord?) -> OlcrtcConnection? {
        guard case .olcrtc(let p)? = record?.details else { return nil }
        return p
    }

    private func invitedHost() -> ServerHost {
        var host = ServerHost(label: "My server", host: "198.51.100.7")
        host.port = 8443
        host.username = "agent"
        host.agentOnly = true
        host.agentRole = "owner"
        return host
    }

    private func withStores(_ body: (ConnectionStore, ServerHostStore) throws -> Void) rethrows {
        let suite = "InvitedBundleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let connections = ConnectionStore(defaults: defaults)
        let hosts = ServerHostStore(defaults: defaults)
        defer {
            for record in connections.connections { ConnectionSecretStore.remove(connectionID: record.id) }
            defaults.removePersistentDomain(forName: suite)
        }
        try body(connections, hosts)
    }

    func testTheListCarriesOneWholeServerRecordAndAProtocolWithRooms() {
        for last in [false, true] {
            let list = records(wholeServerLast: last)
            XCTAssertEqual(list.count, 4)
            let whole = list.first { $0.name == "Whole server" }
            let telemost = list.first { $0.name == "Srv · Telemost" }
            XCTAssertEqual(params(whole)?.isBundle, true)
            XCTAssertEqual(params(whole)?.bond, bond)
            XCTAssertEqual(params(whole)?.lanes.count, 4)
            XCTAssertEqual(params(telemost)?.isBundle, false)
            XCTAssertEqual(params(telemost)?.lanes.count, 2, "a protocol with an extra room has two lanes too")
        }
    }

    func testTheHostLinksTheWholeServerRecordByItsMarkerInEitherOrder() {
        for last in [false, true] {
            let list = records(wholeServerLast: last)
            withStores { connections, hosts in
                connections.connections = list
                let host = invitedHost()
                hosts.hosts = [host]
                InvitedServerPairing.link(host, source: source, hosts: hosts, connections: connections)
                let linked = hosts.hosts[0]
                let whole = list.first { $0.name == "Whole server" }
                XCTAssertEqual(linked.bundleConnectionID, whole?.id, "whole-server record last: \(last)")
                let protocolIDs = [linked.lastConnectionID].compactMap { $0 } + (linked.extraConnectionIDs ?? [])
                XCTAssertEqual(Set(protocolIDs), Set(list.filter { $0.name != "Whole server" }.map(\.id)))
                XCTAssertFalse(protocolIDs.contains { $0 == whole?.id })
            }
        }
    }

    func testBundleSyncLeavesTheRecordsOfAnInvitedServerAlone() {
        for last in [false, true] {
            let list = records(wholeServerLast: last)
            withStores { connections, hosts in
                connections.connections = list
                let host = invitedHost()
                hosts.hosts = [host]
                InvitedServerPairing.link(host, source: source, hosts: hosts, connections: connections)
                let before = connections.connections
                let linkedBefore = hosts.hosts
                let sync = BundleSync(connections: connections, hosts: hosts)
                sync.syncAll()
                XCTAssertEqual(connections.connections, before, "whole-server record last: \(last)")
                XCTAssertEqual(hosts.hosts, linkedBefore)
                let whole = connections.connections.first { $0.name == "Whole server" }
                XCTAssertEqual(params(whole)?.bond, bond, "the list's bond stays")
                let telemost = connections.connections.first { $0.name == "Srv · Telemost" }
                XCTAssertEqual(params(telemost)?.bond, bond)
                XCTAssertEqual(params(telemost)?.isBundle, false, "a protocol record stays a protocol record")
            }
        }
    }

    func testBundleSyncStillBuildsTheWholeServerRecordOfAnOwnServer() {
        withStores { connections, hosts in
            let jazz = ConnectionRecord(name: "own · SaluteJazz", details: .olcrtc(OlcrtcConnection(
                carrier: "salutejazz", transport: "datachannel", roomID: "ab12:cd34", key: key, clientID: "default")))
            let vk = ConnectionRecord(name: "own · VK", details: .olcrtc(OlcrtcConnection(
                carrier: "vkcalls", transport: "vp8channel", roomID: "https://vk.com/call/join/fakeroom",
                key: key, clientID: "default")))
            connections.connections = [jazz, vk]
            var host = ServerHost(label: "own", host: "203.0.113.7")
            host.lastConnectionID = jazz.id
            host.extraConnectionIDs = [vk.id]
            hosts.hosts = [host]
            let sync = BundleSync(connections: connections, hosts: hosts)
            sync.syncAll()
            let bundleID = hosts.hosts[0].bundleConnectionID
            XCTAssertNotNil(bundleID)
            XCTAssertEqual(params(connections.connections.first { $0.id == bundleID })?.isBundle, true)
        }
    }
}
