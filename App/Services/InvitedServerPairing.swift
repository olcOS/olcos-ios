import CryptoKit
import Foundation
import UIKit

// MARK: - Taking server access from a device invite
//
// An invite can carry server access (`#agent*` lines in its list): where the
// agent is, the certificate it pins, the API prefix, a one-time pairing code
// and the role it grants. This phone redeems the code once with its own device
// key and keeps the server as an agent-only host: no SSH login, every command
// runs through the agent (`SSHSecret.agent` → `SSHRunner.ServerLink.agent`),
// and the connections the list brought are linked to it like the ones a
// self-installed server produces.

@MainActor
enum InvitedServerPairing {
    enum Outcome: Equatable {
        case paired(role: String)
        /// The same offer again (a refreshed list): the code is one-time, so
        /// nothing is redeemed; the links are refreshed.
        case alreadyPaired
        /// Nothing answered: the offer is kept and tried again once a session
        /// runs through this server.
        case pending(String)
        case failed(String)
    }

    /// Pairs with the agent the offer names and keeps the server; the name of
    /// the list names the host. `source` is the invite's link without its key:
    /// the records it imported carry it as their provenance.
    static func take(offer: AgentOffer, listName: String?, source: String,
                     hosts: ServerHostStore, connections: ConnectionStore) async -> Outcome {
        // This phone runs the server itself (SSH) and holds its agent: redeeming
        // the code would re-register this phone's key with the invite's role,
        // and a member's code would cost the owner its rights.
        if hosts.hosts.contains(where: { !$0.isAgentOnly && holds($0, offer) }) {
            forgetPending(source: source)
            return .alreadyPaired
        }
        if let existing = hosts.hosts.first(where: {
            $0.isAgentOnly && $0.host == offer.host && $0.agent?.prefix == offer.prefix
        }) {
            link(existing, source: source, hosts: hosts, connections: connections)
            forgetPending(source: source)
            return .alreadyPaired
        }
        // Through the live session first when it runs through this invite's
        // rooms (an in-app proxy session: under the system VPN the direct
        // route goes through the tunnel already).
        let liveSource = TunnelManager.liveRecordID.flatMap { live in
            connections.connections.first { $0.id == live }?.subSourceURL
        }
        let viaTunnel = liveSource.map { sameServer($0, source: source, host: offer.host) } ?? false
        do {
            let key = try AgentDeviceKeyStore.loadOrCreate()
            let result = try await AgentClient.pair(offer: offer, key: key, name: deviceName(), viaTunnel: viaTunnel)
            let label = (listName ?? "").trimmingCharacters(in: .whitespaces)
            var host = ServerHost(label: label.isEmpty ? offer.host : label, host: offer.host)
            host.port = offer.port          // the agent's port: the reachability probe dials it
            host.username = "agent"
            host.agentOnly = true
            host.agentRole = result.role
            host.agent = AgentEndpoint(port: offer.port, certSHA256: offer.certSHA256,
                                       prefix: offer.prefix, version: "", deviceID: result.deviceID)
            hosts.add(host, secret: .agent)
            link(host, source: source, hosts: hosts, connections: connections)
            LogStore.shared.log(.provisioning, "+ server access taken on \(offer.host) as \(result.role)")
            forgetPending(source: source)
            noteSettled(code: offer.code, source: source)
            return .paired(role: result.role)
        } catch {
            let reason = AgentClient.reason(error)
            if isWorthRetrying(error) {
                keepPending(Pending(source: source, listName: listName, offer: offer))
                LogStore.shared.log(.provisioning,
                    "… server access on \(offer.host) not confirmed yet (\(reason)); kept until a session runs through it")
                return .pending(reason)
            }
            forgetPending(source: source)
            noteSettled(code: offer.code, source: source)
            LogStore.shared.log(.provisioning, "✗ server access on \(offer.host) not taken: \(reason)")
            return .failed(reason)
        }
    }

    /// PURE: whether a record's list belongs to the server an offer names: the
    /// same invite, or another invite served from the server's own address.
    nonisolated static func sameServer(_ recordSource: String, source: String, host: String) -> Bool {
        if ConnectionStore.canonicalSource(recordSource) == ConnectionStore.canonicalSource(source) { return true }
        guard let endpoint = InviteLink.endpoint(of: recordSource) else { return false }
        return endpoint.host.caseInsensitiveCompare(host) == .orderedSame
    }

    /// PURE: whether a saved host already holds the agent an offer names.
    nonisolated static func holds(_ host: ServerHost, _ offer: AgentOffer) -> Bool {
        host.host == offer.host && host.agent?.prefix == offer.prefix
    }

    /// A refreshed list still carries server access this phone does not hold.
    /// Its first try may have met an agent that did not know the code yet, or
    /// found no route: the offer waits for the next session through the
    /// server, where an answer settles it. A code that already got its answer
    /// (taken, refused or spent) is not offered again: the list keeps carrying
    /// it, and each refresh would only buy the same refusal after the next
    /// connect, forever. Opening the invite link again still tries it.
    static func noteRefreshed(offer: AgentOffer, listName: String?, source: String, hosts: ServerHostStore,
                              defaults: UserDefaults = .standard) {
        guard !hosts.hosts.contains(where: { holds($0, offer) }),
              !isSettled(code: offer.code, source: source, defaults: defaults) else { return }
        keepPending(Pending(source: source, listName: listName, offer: offer))
    }

    // MARK: - Codes that got their answer

    /// SHA-256 of each code that got a final answer, with the list it came in
    /// (a code grants access, so only hashes are kept), the newest
    /// `settledLimit` of them.
    static let settledKey = "olcos.invite.settledCodes"
    static let settledLimit = 64

    nonisolated static func settledID(code: String, source: String) -> String {
        let text = ConnectionStore.canonicalSource(source) + "\n" + code
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isSettled(code: String, source: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: settledKey) ?? []).contains(settledID(code: code, source: source))
    }

    static func noteSettled(code: String, source: String, defaults: UserDefaults = .standard) {
        let id = settledID(code: code, source: source)
        var list = (defaults.stringArray(forKey: settledKey) ?? []).filter { $0 != id }
        list.append(id)
        if list.count > settledLimit { list.removeFirst(list.count - settledLimit) }
        defaults.set(list, forKey: settledKey)
    }

    /// PURE: whether a pairing that failed this way may go through later. Only
    /// when nothing answered: an answer (the code refused or spent) is final,
    /// and so is a certificate that is not the one the invite pins. An answer
    /// cut off on the way (`badResponse`) is not one: the agent may have paired
    /// this key, and a pair asked again by the same key gets the same answer.
    nonisolated static func isWorthRetrying(_ error: Error) -> Bool {
        guard let failure = error as? AgentHTTPS.Failure else { return false }
        switch failure {
        // was: case .timeout, .network, .noTunnel — a cut-off answer settled the code.
        case .timeout, .network, .noTunnel, .badResponse: return true
        default: return false
        }
    }

    // MARK: - Offers kept for later

    /// An offer whose pairing found no route yet. It stays in the Keychain (its
    /// code grants server access) until a session runs through that server.
    struct Pending: Codable, Equatable {
        var source: String
        var listName: String?
        var host: String
        var port: Int
        var certSHA256: String
        var prefix: String
        var code: String
        var role: String

        init(source: String, listName: String?, offer: AgentOffer) {
            self.source = source
            self.listName = listName
            host = offer.host
            port = offer.port
            certSHA256 = offer.certSHA256
            prefix = offer.prefix
            code = offer.code
            role = offer.role
        }

        var offer: AgentOffer {
            AgentOffer(host: host, port: port, certSHA256: certSHA256, prefix: prefix, code: code, role: role)
        }
    }

    private static let pendingService = "olcos.invite.pairing"
    private static let pendingAccount = "pending"

    static func pendingOffers() -> [Pending] {
        guard let text = KeychainHelper.get(service: pendingService, account: pendingAccount),
              let list = try? JSONDecoder().decode([Pending].self, from: Data(text.utf8)) else { return [] }
        return list
    }

    static func savePending(_ list: [Pending]) {
        guard !list.isEmpty else {
            KeychainHelper.delete(service: pendingService, account: pendingAccount)
            return
        }
        guard let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) else { return }
        _ = KeychainHelper.set(text, service: pendingService, account: pendingAccount)
    }

    private static func keepPending(_ item: Pending) {
        let canon = ConnectionStore.canonicalSource(item.source)
        savePending(pendingOffers().filter { ConnectionStore.canonicalSource($0.source) != canon } + [item])
    }

    static func forgetPending(source: String) {
        let canon = ConnectionStore.canonicalSource(source)
        let list = pendingOffers()
        let kept = list.filter { ConnectionStore.canonicalSource($0.source) != canon }
        if kept.count != list.count { savePending(kept) }
    }

    /// Tries the kept offers of the server the live session's record belongs
    /// to: a session through that server reaches its agent.
    static func retryPending(liveRecord: ConnectionRecord?, hosts: ServerHostStore,
                             connections: ConnectionStore) async {
        guard let source = liveRecord?.subSourceURL else { return }
        for item in pendingOffers() where sameServer(source, source: item.source, host: item.host) {
            let outcome = await take(offer: item.offer, listName: item.listName, source: item.source,
                                     hosts: hosts, connections: connections)
            if case .paired(let role) = outcome {
                LogStore.shared.log(.connection, "⬇ invite: server access confirmed through the session (\(role))")
            }
        }
    }

    /// The connections the invite brought belong to the host: the card shows
    /// them, the agent's tunnel route is tried through them, and the host's
    /// own invites carry them. Re-run after every refresh of the list. The
    /// whole-server record is the one the list marks as such (`##with`), not
    /// the first with several rooms: a protocol with extra rooms has those
    /// too, and the list may put the whole-server record anywhere.
    static func link(_ host: ServerHost, source: String, hosts: ServerHostStore, connections: ConnectionStore) {
        guard var fresh = hosts.hosts.first(where: { $0.id == host.id }) else { return }
        let canon = ConnectionStore.canonicalSource(source)
        var olcrtc: [UUID] = []
        var bundle: UUID?
        var xray: UUID?
        for record in connections.connections
        where record.subSourceURL.map(ConnectionStore.canonicalSource) == canon {
            switch record.details {
            case .olcrtc(let params):
                if params.isBundle {
                    if bundle == nil { bundle = record.id }
                } else {
                    olcrtc.append(record.id)
                }
            case .xray:
                if xray == nil { xray = record.id }
            }
        }
        fresh.bundleConnectionID = bundle
        fresh.lastConnectionID = olcrtc.first
        fresh.extraConnectionIDs = olcrtc.count > 1 ? Array(olcrtc.dropFirst()) : nil
        fresh.xrayConnectionID = xray
        guard fresh != host else { return }
        hosts.update(fresh, secret: nil)
    }

    /// What the owner sees in the agent's device list.
    static func deviceName() -> String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? UIDevice.current.model : name).prefix(40))
    }
}
