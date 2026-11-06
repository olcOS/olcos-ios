import Foundation

// MARK: - LiveRecordRefresh
//
// What a live session asks when one of its lanes stays out of its room
// (TunnelManager.laneStayedDown): where are this connection's rooms now? A
// record from a list or an invite is re-read from that list; a record of one
// of the user's own servers is matched against the rooms the server lists
// over SSH (the same rules the server card applies, ServersView
// `followedServerRooms` / `syncedLaneRooms`), and its whole-server record is
// rebuilt from them (BundleSync). Returns the record as it is saved after
// that, or nil when it is gone. A failed read changes nothing.

@MainActor
enum LiveRecordRefresh {
    static func refresh(_ record: ConnectionRecord, store: ConnectionStore, hosts: ServerHostStore,
                        bundleSync: BundleSync) async -> ConnectionRecord? {
        if let source = record.subSourceURL {
            _ = await store.refreshSource(source)
        } else if let host = hosts.hosts.first(where: { $0.links(record.id) }), !host.isAgentOnly,
                  let base = host.lastContainerName, let secret = hosts.secret(for: host) {
            do {
                let listed = try await Provisioner().listCarriers(on: host, secret: secret, baseContainer: base)
                let (rows, lanes) = SSHRunner.splitLanes(listed.rows)
                for updated in ServersView.syncedLaneRooms(host: host, carriers: rows, lanes: lanes,
                                                           records: store.connections) {
                    store.update(updated)
                }
                for updated in ServersView.followedServerRooms(host: host, carriers: rows,
                                                               records: store.connections) {
                    store.update(updated)
                    LogStore.shared.log(.connection,
                        "↻ \(host.label): a connection now uses the room the server is in")
                }
                bundleSync.syncAll()
            } catch {
                LogStore.shared.log(.connection,
                    "⚠ \(host.label): could not read the server's rooms — \(error.localizedDescription)")
            }
        }
        return store.connections.first { $0.id == record.id }
    }
}
