import Combine
import Foundation

// MARK: - InviteSync
//
// Creates, keeps current and revokes device invites (DeviceInvite.swift).
//
// It watches the saved connections and servers. When the list a server's
// invites would carry no longer matches the one last uploaded — a renewed
// Telemost room, a rotated key, a protocol added or removed — it encrypts the
// new list for every invite of that server and uploads it over SSH. One pass
// at a time; a failure is kept per server for the invites screen and retried
// on the next change or return to the app. Nothing is uploaded while a secret
// is missing (InvitePayload refuses a list without keys).

@MainActor
final class InviteSync: ObservableObject {

    /// The last upload failure per server, until an upload succeeds.
    @Published private(set) var failures: [UUID: String] = [:]
    /// Servers being uploaded to right now.
    @Published private(set) var busy: Set<UUID> = []

    private let connections: ConnectionStore
    private let hosts: ServerHostStore
    private var observers = Set<AnyCancellable>()
    private var running = false
    private var runAgain = false

    init(connections: ConnectionStore, hosts: ServerHostStore) {
        self.connections = connections
        self.hosts = hosts
        connections.$connections.map { _ in () }
            .merge(with: hosts.$hosts.map { _ in () })
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.syncSoon() } }
            .store(in: &observers)
    }

    func syncSoon() {
        Task { await syncAll() }
    }

    /// Uploads every out-of-date list; a call during a pass schedules one more.
    func syncAll() async {
        guard !running else { runAgain = true; return }
        running = true
        repeat {
            runAgain = false
            for host in hosts.hosts where !(host.invites ?? []).isEmpty {
                await sync(hostID: host.id)
            }
        } while runAgain
        running = false
    }

    /// The list `host`'s invites should carry now; nil when it can't be built.
    /// With `invite`, the list of that one device: its links carry the
    /// invite's id (`inv-<tag>`), and its agent pairing code rides along when
    /// the invite gives server access and the agent exists.
    func currentList(for host: ServerHost, invite: DeviceInvite? = nil) -> String? {
        let records = host.linkedConnectionIDs.compactMap { id in
            connections.connections.first { $0.id == id }
        }
        var offer: AgentOffer?
        if let invite, let agent = host.agent {
            switch Self.accessCode(of: invite) {
            case .success(let code?) where !code.isEmpty:
                offer = AgentOffer(host: host.host, port: agent.port, certSHA256: agent.certSHA256,
                                   prefix: agent.prefix, code: code, role: invite.agentRole ?? "member")
            case .success:
                break
            case .failure:
                // The code exists but the Keychain is still locked: a list
                // without the offer would take the access away from a device
                // that has not paired yet. Nothing is built until it reads.
                return nil
            }
        }
        return InvitePayload.body(serverName: host.label, records: records, agent: offer,
                                  inviteTag: invite?.tag)
    }

    /// The pairing code of an access invite: in memory once the host store
    /// has read it, else straight from the Keychain (the store's read may have
    /// met a Keychain still locked after a restart). `.failure` while locked.
    nonisolated static func accessCode(of invite: DeviceInvite) -> Result<String?, KeychainError> {
        if let code = invite.agentCode, !code.isEmpty { return .success(code) }
        guard invite.agentRole != nil else { return .success(nil) }
        return InviteKeyStore.agentCode(token: invite.token)
    }

    /// Whether invites on `hostID` can give server access (the agent is installed).
    func canGiveServerAccess(hostID: UUID) -> Bool {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return false }
        // Minting a code is an owner call on the agent.
        return host.agent != nil && host.canManage
    }

    /// How much of the server an invite hands over, beside the connections.
    enum Access: String, CaseIterable, Identifiable {
        case none, member, owner
        var id: String { rawValue }
    }

    /// The link for one invite, key included; nil before the first upload
    /// (no port yet) or when the key is gone from the Keychain.
    func link(for invite: DeviceInvite, on host: ServerHost) -> String? {
        guard let port = host.sharePort, let key = InviteKeyStore.key(token: invite.token) else { return nil }
        return InviteLink.encode(host: host.host, port: port, token: invite.token, key: key)
    }

    /// A new invite for `hostID`, uploaded before it is returned. With server
    /// access, the agent mints the device's pairing code first (over SSH);
    /// when that fails the invite is not created, so the user can retry.
    func create(name: String, hostID: UUID, access: Access = .none) async throws -> DeviceInvite {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { throw InviteError.invalidLink }
        guard currentList(for: host) != nil else { throw SyncError.nothingToShare }
        var invite = DeviceInvite(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if access != .none, host.agent != nil {
            guard let secret = hosts.secret(for: host) else { throw SyncError.noCredentials }
            busy.insert(hostID)
            defer { busy.remove(hostID) }
            do {
                let minted = try await SSHRunner.agentInvite(host: host, secret: secret,
                                                             role: access.rawValue, name: invite.name)
                invite.agentCode = minted.code
                invite.agentRole = minted.role
                log("🔑 agent pairing code minted for \(invite.name.isEmpty ? "—" : invite.name) (\(minted.role)) on \(host.label)")
            } catch {
                log("✗ agent pairing code for \(host.label): \(error.localizedDescription)")
                throw SyncError.agentInviteFailed(error.localizedDescription)
            }
        }
        InviteKeyStore.set(InviteLink.makeKey(), token: invite.token)
        hosts.setInvites((host.invites ?? []) + [invite], sharePort: host.sharePort, forHost: hostID)
        if let failure = await upload(hostID: hostID, only: [invite.token]) {
            throw SyncError.uploadFailed(failure)
        }
        return hosts.hosts.first(where: { $0.id == hostID })?.invites?.first { $0.id == invite.id } ?? invite
    }

    /// Deletes the invite's list from the server, then forgets the invite.
    func revoke(_ invite: DeviceInvite, hostID: UUID) async throws {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return }
        if invite.publishedAt != nil || host.sharePort != nil {
            guard let secret = hosts.secret(for: host) else { throw SyncError.noCredentials }
            busy.insert(hostID)
            defer { busy.remove(hostID) }
            let result = try await SSHRunner.deleteInvites(host: host, secret: secret, tokens: [invite.token])
            log("✂ invite \(invite.name.isEmpty ? "—" : invite.name) revoked on \(host.label)"
                + (result.stopped ? "; share server removed" : ""))
            // The agent side: burn the pairing code and revoke the device that used it.
            switch Self.accessCode(of: invite) {
            case .success(let code?) where !code.isEmpty:
                do {
                    let revoked = try await SSHRunner.agentRevokeInvite(host: host, secret: secret, code: code)
                    log(revoked == "-" ? "🔑 agent pairing code burned on \(host.label) (no device had used it)"
                                       : "🔑 agent access revoked on \(host.label): device \(revoked)")
                } catch {
                    log("✗ agent access on \(host.label) not revoked: \(error.localizedDescription)")
                }
            case .success:
                break
            case .failure:
                log("✗ agent access on \(host.label) not revoked: the Keychain is locked")
            }
            forget(invite, hostID: hostID, serverStopped: result.stopped)
        } else {
            forget(invite, hostID: hostID, serverStopped: false)
        }
    }

    private func forget(_ invite: DeviceInvite, hostID: UUID, serverStopped: Bool) {
        InviteKeyStore.remove(token: invite.token)
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return }
        let rest = (host.invites ?? []).filter { $0.id != invite.id }
        hosts.setInvites(rest, sharePort: serverStopped ? nil : host.sharePort, forHost: hostID)
    }

    private func sync(hostID: UUID) async {
        _ = await upload(hostID: hostID, only: nil)
    }

    /// Uploads the current list to the host's out-of-date invites (or to the
    /// named ones regardless). Returns the failure, nil on success.
    private func upload(hostID: UUID, only tokens: Set<String>?) async -> String? {
        guard let host = hosts.hosts.first(where: { $0.id == hostID }),
              let invites = host.invites, !invites.isEmpty,
              currentList(for: host) != nil else { return nil }
        // Each invite has a list of its own (its pairing code is in it), so the
        // digest that says "out of date" is per invite too.
        var digests: [String: String] = [:]
        for invite in invites {
            if let body = currentList(for: host, invite: invite) {
                digests[invite.token] = InvitePayload.digest(body)
            }
        }
        let due = invites.filter { invite in
            tokens.map { $0.contains(invite.token) } ?? (invite.publishedDigest != digests[invite.token])
        }
        guard !due.isEmpty else { return nil }
        guard let secret = hosts.secret(for: host) else {
            failures[hostID] = SyncError.noCredentials.localizedDescription
            return failures[hostID]
        }
        var lists: [(token: String, served: String)] = []
        for invite in due {
            guard let body = currentList(for: host, invite: invite),
                  let key = InviteKeyStore.key(token: invite.token),
                  let served = try? InviteCipher.seal(body, key: key) else { continue }
            lists.append((invite.token, served))
        }
        guard !lists.isEmpty else { return nil }
        busy.insert(hostID)
        defer { busy.remove(hostID) }
        do {
            let result = try await SSHRunner.publishInvites(host: host, secret: secret, lists: lists)
            // The host may have changed during the upload; apply to the fresh copy.
            guard let fresh = hosts.hosts.first(where: { $0.id == hostID }) else { return nil }
            let now = Date()
            let updated = (fresh.invites ?? []).map { invite -> DeviceInvite in
                guard result.written.contains(invite.token) else { return invite }
                var copy = invite
                copy.publishedAt = now
                copy.publishedDigest = digests[invite.token]
                return copy
            }
            hosts.setInvites(updated, sharePort: result.port ?? fresh.sharePort, forHost: hostID)
            failures[hostID] = nil
            log("⬆ invites for \(host.label): \(result.written.count) list(s) uploaded")
            return nil
        } catch {
            failures[hostID] = error.localizedDescription
            log("✗ invites for \(host.label): \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    private func log(_ line: String) {
        LogStore.shared.log(.provisioning, line)
    }

    enum SyncError: LocalizedError, Equatable {
        case nothingToShare
        case noCredentials
        case uploadFailed(String)
        case agentInviteFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToShare:             return L10n.inviteErrorNothingToShare.localized()
            case .noCredentials:              return L10n.inviteErrorNoCredentials.localized()
            case .uploadFailed(let why):      return L10n.inviteErrorUploadFailed_fmt.formatted(why)
            case .agentInviteFailed(let why): return L10n.invitesAccessMintFailed_fmt.formatted(why)
            }
        }
    }
}
