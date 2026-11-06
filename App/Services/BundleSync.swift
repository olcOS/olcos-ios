import Combine
import Foundation

// MARK: - BundleSync
//
// Keeps every server's whole-server connection (ServerBundle) in step with
// its protocol records, and the server's bond endpoint deployed.
//
// It watches the saved connections and servers. For each server whose
// protocols and rooms make two lanes or more, it writes the whole-server
// record (adding it in front of the server's records and selecting it when
// one of them was selected), corrects it when a protocol record changes and
// removes it when the server is down to one lane. A server that has no bond
// endpoint of this app's version gets one over SSH, in the background, one
// server at a time; a failure is kept per server and retried after a while.
// Nothing is written while the Keychain is still locked.
//
// A server taken from a device invite (agent-only) is left alone: its
// whole-server record and bond come from the invite's list, which the owner's
// phone keeps current, and this phone never deploys an endpoint there. A
// rebuild here had no endpoint to give, so it dropped the list's bond and
// the lanes took turns instead of carrying together.

@MainActor
final class BundleSync: ObservableObject {

    /// The last bond deployment failure per server, until one succeeds.
    @Published private(set) var failures: [UUID: String] = [:]
    /// Servers getting their bond endpoint right now.
    @Published private(set) var deploying: Set<UUID> = []

    /// How long a failed deployment waits before the next try.
    static let retryAfter: TimeInterval = 10 * 60

    private let connections: ConnectionStore
    private let hosts: ServerHostStore
    private var observers = Set<AnyCancellable>()
    private var lastAttempt: [UUID: Date] = [:]
    private var version: String?

    init(connections: ConnectionStore, hosts: ServerHostStore) {
        self.connections = connections
        self.hosts = hosts
        connections.$connections.map { _ in () }
            .merge(with: hosts.$hosts.map { _ in () })
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.syncAll() } }
            .store(in: &observers)
    }

    func syncAll() {
        guard !connections.secretsLocked else { return }
        for host in hosts.hosts where Self.keepsInStep(host) {
            syncProtocolBonds(hostID: host.id)
            syncRecord(hostID: host.id)
            if needsBond(host) { deploy(hostID: host.id) }
        }
    }

    /// Whether this phone derives the server's whole-server record and bond:
    /// not for a server an invite brought (see the header).
    nonisolated static func keepsInStep(_ host: ServerHost) -> Bool { !host.isAgentOnly }

    /// A protocol with extra rooms bonds them over the server's endpoint too.
    private func syncProtocolBonds(hostID: UUID) {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return }
        let endpoint = ServerBundle.endpoint(host: host)
        for id in [host.lastConnectionID].compactMap({ $0 }) + (host.extraConnectionIDs ?? []) {
            guard var record = connections.connections.first(where: { $0.id == id }),
                  case .olcrtc(var params) = record.details else { continue }
            let wanted = ServerBundle.bond(for: params, endpoint: endpoint)
            guard params.bond != wanted else { continue }
            params.bond = wanted
            record.details = .olcrtc(params)
            connections.update(record)
        }
    }

    /// The protocol records of a server, the primary first.
    private func protocols(of host: ServerHost) -> [OlcrtcConnection] {
        ([host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? [])).compactMap { id in
            guard let record = connections.connections.first(where: { $0.id == id }),
                  case .olcrtc(let params) = record.details else { return nil }
            return params
        }
    }

    private func syncRecord(hostID: UUID) {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return }
        let existing = host.bundleConnectionID.flatMap { id in connections.connections.first { $0.id == id } }
        guard var params = ServerBundle.params(protocols: protocols(of: host),
                                               bond: ServerBundle.endpoint(host: host)) else {
            // One lane left, or no protocol at all: the protocol's own record
            // says everything the whole-server one did.
            if let existing {
                connections.remove(id: existing.id)
                LogStore.shared.log(.connection, "− whole-server connection of \(host.label) removed")
            }
            hosts.setBundle(nil, forHost: hostID)
            return
        }
        if let existing, case .olcrtc(let old) = existing.details {
            // The local SOCKS credentials are the user's, set on this record.
            params.socksUser = old.socksUser
            params.socksPass = old.socksPass
            guard old != params else { return }
            var updated = existing
            updated.details = .olcrtc(params)
            connections.update(updated)
            return
        }
        let siblings = [host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? [])
        let group = siblings.lazy.compactMap { id in self.connections.connections.first { $0.id == id } }
            .first?.groupName ?? ConnectionRecord.defaultGroupName
        let record = ConnectionRecord(name: host.label, groupName: group, details: .olcrtc(params))
        let wasSelected = connections.primaryID.map { siblings.contains($0) } ?? true
        connections.add(record)
        hosts.setBundle(record.id, forHost: hostID)
        if wasSelected { connections.setPrimary(record.id) }
        LogStore.shared.log(.connection,
            "＋ whole-server connection of \(host.label): \(params.lanes.count) lanes"
            + (params.bond != nil ? ", bonded" : ""))
    }

    /// A server with two lanes or more and no endpoint of this app's version,
    /// not tried too recently.
    private func needsBond(_ host: ServerHost) -> Bool {
        let lanes = host.bundleConnectionID != nil || protocols(of: host).contains { $0.lanes.count > 1 }
        guard lanes, host.lastContainerName != nil, !deploying.contains(host.id) else { return false }
        if version == nil, let sources = try? SSHRunner.bondSources() {
            version = SSHRunner.bondVersion(sources)
        }
        guard let version, host.bondPort == nil || host.bondVersion != version else { return false }
        if let last = lastAttempt[host.id], Date().timeIntervalSince(last) < Self.retryAfter { return false }
        return true
    }

    private func deploy(hostID: UUID) {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }),
              let secret = hosts.secret(for: host) else { return }
        deploying.insert(hostID)
        lastAttempt[hostID] = Date()
        Task {
            defer { deploying.remove(hostID) }
            do {
                let (port, version) = try await SSHRunner.ensureBond(host: host, secret: secret)
                hosts.setBond(port: port, version: version, forHost: hostID)
                failures[hostID] = nil
                LogStore.shared.log(.provisioning, "⇉ bond endpoint on \(host.label): port \(port)")
                syncProtocolBonds(hostID: hostID)
                syncRecord(hostID: hostID)
            } catch {
                failures[hostID] = error.localizedDescription
                LogStore.shared.log(.provisioning, "✗ bond endpoint on \(host.label): \(error.localizedDescription)")
            }
        }
    }
}
