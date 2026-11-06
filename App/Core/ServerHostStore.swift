import Foundation

// MARK: - ServerHostStore
//
// Saves the list of SSH-reachable VPS hosts. Non-secret fields go to
// UserDefaults as JSON; the password lives in iOS Keychain under a
// per-host UUID key. See KeychainHelper for the underlying primitives.

@MainActor
final class ServerHostStore: ObservableObject {
    @Published var hosts: [ServerHost] = [] {
        didSet { save() }
    }
    private var isLoading = false // #482: decoding is not an explicit edit.
    private let defaults: UserDefaults // #482: isolated persistence tests.

    // MARK: Resolved-secret cache (round 2, D)
    //
    // `secret(for:)` is what every SSH pass on the Servers tab resolves first,
    // and it was ALSO reached from the card's render path (ServersView
    // `menuItems` → `shareRequest` → the full-access payload), which meant one or
    // two synchronous `SecItemCopyMatching` calls per host per body
    // evaluation. The render path no longer asks for the secret at all; the
    // async paths still do, once per host per pass, so the resolved value is
    // kept HERE, in memory only, after the first successful read:
    //  • memory-only — never encoded, never logged, never in UserDefaults;
    //  • keyed by host id AND auth method, so a method switch is a miss;
    //  • only a HIT is cached — a miss (Keychain still locked right after a
    //    reboot, entry wiped) is re-asked next time, so nothing is ever
    //    remembered as "absent";
    //  • dropped on every write or removal below, and on `invalidateSecrets()`
    //    (once per foreground, from the tab that owns the store).
    private struct SecretCacheKey: Hashable {
        let id: UUID
        let method: SSHAuthMethod? // `ServerHost.authMethod` is optional (nil = legacy password host)
    }
    private var secretCache: [SecretCacheKey: SSHSecret] = [:]

    /// Forget every resolved credential; the next `secret(for:)` re-reads the
    /// Keychain. Called once per foreground so a credential changed by another
    /// process (or a Keychain that became readable after first unlock) is
    /// picked up without a per-render read.
    func invalidateSecrets() {
        secretCache.removeAll()
    }

    private func forgetSecret(for host: ServerHost) {
        secretCache = secretCache.filter { $0.key.id != host.id }
    }

    private let storeKey = "olcrtc_server_hosts"
    private static let keychainService = "olcrtc.serverhost.password"
    // #451: SSH private-key auth. Same per-host account key (id.uuidString) as
    // the password; separate services so a host can hold both (e.g. after
    // switching methods) without clobbering. `nonisolated` — immutable names,
    // read by the nonisolated `resolveSecret` bridge below.
    nonisolated private static let privateKeyService    = "olcrtc.serverhost.privatekey"
    nonisolated private static let keyPassphraseService = "olcrtc.serverhost.keypassphrase"

    /// What the Keychain holds for each access invite's pairing code, as this
    /// process last wrote or read it, by invite token: a save writes only the
    /// codes that changed.
    private var storedAgentCodes: [String: String] = [:]

    // #482 was: init() { load() }, always touching real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // A list saved before the pairing codes moved to the Keychain still
        // carries them: one save moves them there and blanks them here.
        if hasUnstoredAgentCodes { save() }
    }

    /// Legacy password-only add — kept verbatim for pre-#451 call sites.
    /// Adds a password-auth host.
    func add(_ host: ServerHost, password: String) {
        add(host, secret: .password(password))
    }

    /// #451: adds a host with either credential kind.
    func add(_ host: ServerHost, secret: SSHSecret) {
        hosts.append(host)
        writeSecret(secret, for: host)
        LogStore.shared.log(.provisioning,
            "+ added VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]" +
            (host.authMethod == .privateKey ? " (SSH key)" : ""))
    }

    /// Legacy update — `password` nil/empty leaves the stored credentials
    /// untouched (the "(password changed)" contract every pre-#451 caller
    /// relies on). #451: a NON-empty password through this API also flips a
    /// key-auth host back to password auth.
    func update(_ host: ServerHost, password: String?) {
        var h = host
        if let pw = password, !pw.isEmpty, h.authMethod == .privateKey {
            h.authMethod = .password
        }
        if let i = hosts.firstIndex(where: { $0.id == h.id }) {
            hosts[i] = h
            LogStore.shared.log(.provisioning,
                "✎ updated VPS: \(h.label) [\(h.username)@\(h.host):\(h.port)]" +
                ((password ?? "").isEmpty ? "" : " (password changed)"))
        }
        if let pw = password, !pw.isEmpty {
            forgetSecret(for: host)
            KeychainHelper.set(pw, service: Self.keychainService, account: host.id.uuidString)
        }
    }

    /// #451: update with either credential kind; `secret` nil leaves the
    /// stored credentials untouched.
    func update(_ host: ServerHost, secret: SSHSecret?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
            LogStore.shared.log(.provisioning,
                "✎ updated VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]" +
                (secret == nil ? "" : " (credentials changed)"))
        }
        if let secret { writeSecret(secret, for: host) }
    }

    private func writeSecret(_ secret: SSHSecret, for host: ServerHost) {
        forgetSecret(for: host)
        let account = host.id.uuidString
        switch secret {
        case .password(let pw):
            KeychainHelper.set(pw, service: Self.keychainService, account: account)
        case .agent:
            break   // nothing to keep: the device key lives in AgentDeviceKeyStore
        case .privateKey(let text, let passphrase):
            KeychainHelper.set(text, service: Self.privateKeyService, account: account)
            if let pp = passphrase, !pp.isEmpty {
                KeychainHelper.set(pp, service: Self.keyPassphraseService, account: account)
            } else {
                // Unencrypted key — make sure no stale passphrase survives a
                // key swap (a wrong passphrase would fail the decrypt).
                KeychainHelper.delete(service: Self.keyPassphraseService, account: account)
            }
        }
    }

    /// The host's device invites and share port, as InviteSync records each
    /// upload. Not logged: a republish is routine, and InviteSync logs its own.
    func setInvites(_ invites: [DeviceInvite], sharePort: Int?, forHost id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].invites = invites.isEmpty ? nil : invites
        hosts[i].sharePort = sharePort
    }

    /// The whole-server record BundleSync keeps for the host.
    func setBundle(_ recordID: UUID?, forHost id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }),
              hosts[i].bundleConnectionID != recordID else { return }
        hosts[i].bundleConnectionID = recordID
    }

    /// Where the host's bond endpoint answers, and which sources it runs.
    func setBond(port: Int?, version: String?, forHost id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }),
              hosts[i].bondPort != port || hosts[i].bondVersion != version else { return }
        hosts[i].bondPort = port
        hosts[i].bondVersion = version
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { hosts.indices.contains($0) ? hosts[$0] : nil }
        for h in removed {
            forgetSecret(for: h)
            for invite in h.invites ?? [] {
                InviteKeyStore.remove(token: invite.token)
                storedAgentCodes[invite.token] = nil
            }
            // #451: sweep every credential service, whatever authMethod says —
            // a method switch may have left entries under the other services.
            KeychainHelper.delete(service: Self.keychainService,     account: h.id.uuidString)
            KeychainHelper.delete(service: Self.privateKeyService,   account: h.id.uuidString)
            KeychainHelper.delete(service: Self.keyPassphraseService, account: h.id.uuidString)
        }
        hosts.remove(atOffsets: idx)
        for h in removed {
            LogStore.shared.log(.provisioning, "− removed VPS: \(h.label) [\(h.host)]")
        }
    }

    /// The host's stored credential MATERIAL — the password for password
    /// hosts, and (#451) the private-key TEXT for key hosts. The key-host
    /// case exists so legacy `guard let pw = password(for:)` call sites that
    /// cannot be updated in lock-step (LogsView's container-log fetch) still
    /// see a non-nil credential; those sites hand the string to Provisioner's
    /// `password:`-labelled compatibility overloads, which re-resolve the full
    /// SSHSecret (key + passphrase) via `resolveSecret(for:credential:)`.
    /// Sites that need strictly the password (edit-sheet prefill) must gate
    /// on `host.authMethod` first.
    func password(for host: ServerHost) -> String? {
        if host.isAgentOnly { return "" }   // resolveSecret turns it back into `.agent`
        if host.authMethod == .privateKey {
            return KeychainHelper.get(service: Self.privateKeyService, account: host.id.uuidString)
        }
        return KeychainHelper.get(service: Self.keychainService, account: host.id.uuidString)
    }

    /// #451: the stored private-key text for a host (any auth method) — used
    /// by the edit sheet to prefill the key editor. nil when never stored.
    func privateKey(for host: ServerHost) -> String? {
        KeychainHelper.get(service: Self.privateKeyService, account: host.id.uuidString)
    }

    /// #451: the stored key passphrase, nil for unencrypted keys.
    func keyPassphrase(for host: ServerHost) -> String? {
        KeychainHelper.get(service: Self.keyPassphraseService, account: host.id.uuidString)
    }

    /// #451: the host's full SSHSecret, resolved per `authMethod`. nil when
    /// the Keychain has no entry (never saved / wiped) — callers surface the
    /// method-appropriate "credential missing" message.
    /// Served from the in-memory cache after the first successful read (see
    /// the cache notes at the top of the class); a miss is never cached.
    func secret(for host: ServerHost) -> SSHSecret? {
        // An invited host has no login to read: its commands go through the agent.
        if host.isAgentOnly { return .agent }
        let key = SecretCacheKey(id: host.id, method: host.authMethod)
        if let cached = secretCache[key] { return cached }
        guard let resolved = readSecret(for: host) else { return nil }
        secretCache[key] = resolved
        return resolved
    }

    /// The uncached Keychain read behind `secret(for:)`.
    private func readSecret(for host: ServerHost) -> SSHSecret? {
        if host.authMethod == .privateKey {
            guard let key = KeychainHelper.get(service: Self.privateKeyService,
                                               account: host.id.uuidString) else { return nil }
            return .privateKey(text: key,
                               passphrase: KeychainHelper.get(service: Self.keyPassphraseService,
                                                              account: host.id.uuidString))
        }
        guard let pw = KeychainHelper.get(service: Self.keychainService,
                                          account: host.id.uuidString) else { return nil }
        return .password(pw)
    }

    /// #451: bridge for the String-credential compatibility overloads on
    /// Provisioner (see `password(for:)` above): `credential` is whatever
    /// `password(for:)` returned — the password for password hosts, the key
    /// text for key hosts (the passphrase is re-read from the Keychain).
    /// nonisolated + static so the @MainActor Provisioner can call it without
    /// holding a store reference.
    nonisolated static func resolveSecret(for host: ServerHost, credential: String) -> SSHSecret {
        if host.isAgentOnly { return .agent }
        guard host.authMethod == .privateKey else { return .password(credential) }
        return .privateKey(text: credential,
                           passphrase: KeychainHelper.get(service: keyPassphraseService,
                                                          account: host.id.uuidString))
    }

    // MARK: Persistence

    private func save() {
        guard !isLoading else { return } // #482: preserve the exact loaded bytes.
        // An access invite's pairing code grants server access: it goes to the
        // Keychain (InviteKeyStore) and is blanked in the saved list, the way
        // ConnectionStore keeps connection secrets. Should the Keychain refuse
        // the write, the code stays where it already was rather than be lost;
        // the next save moves it.
        let scrubbed = hosts.map { host -> ServerHost in
            guard let invites = host.invites else { return host }
            var copy = host
            copy.invites = invites.map { invite -> DeviceInvite in
                guard let code = invite.agentCode, !code.isEmpty,
                      storeAgentCode(code, token: invite.token) else { return invite }
                var blanked = invite
                blanked.agentCode = nil
                return blanked
            }
            return copy
        }
        if let data = try? JSONEncoder().encode(scrubbed) {
            // #482 was: set(data, forKey: storeKey), bypassing recovery protection.
            SavedListRecovery.save(data, as: [ServerHost].self, key: storeKey, defaults: defaults) // #482
        }
    }

    /// Writes an invite's pairing code to the Keychain unless it already holds
    /// it; false when the Keychain refused.
    private func storeAgentCode(_ code: String, token: String) -> Bool {
        if storedAgentCodes[token] == code { return true }
        guard InviteKeyStore.setAgentCode(code, token: token) else { return false }
        storedAgentCodes[token] = code
        return true
    }

    /// Whether an invite in memory holds a pairing code the Keychain does not.
    private var hasUnstoredAgentCodes: Bool {
        hosts.contains { host in
            (host.invites ?? []).contains { invite in
                guard let code = invite.agentCode, !code.isEmpty else { return false }
                return storedAgentCodes[invite.token] != code
            }
        }
    }

    /// The host with its access invites' pairing codes read back from the
    /// Keychain. A read the Keychain refuses (still locked after a restart)
    /// leaves the code out; the publisher asks again when it needs it
    /// (InviteSync.accessCode).
    private func hydratingAgentCodes(_ host: ServerHost) -> ServerHost {
        guard let invites = host.invites else { return host }
        var copy = host
        copy.invites = invites.map { invite -> DeviceInvite in
            guard invite.agentRole != nil, (invite.agentCode ?? "").isEmpty,
                  case .success(let code?) = InviteKeyStore.agentCode(token: invite.token) else { return invite }
            storedAgentCodes[invite.token] = code
            var hydrated = invite
            hydrated.agentCode = code
            return hydrated
        }
        return copy
    }
    // #482 was: backupKey = "olcrtc_server_hosts.unreadable", a write-only
    // parking place. SavedListRecovery now reads and protects it.

    // #470 was: `if let data = …, let list = try? JSONDecoder().decode(…) { hosts = list }`
    private func load() {
        // boc #482: hosts had the same parked-but-never-read backup defect.
        isLoading = true
        defer { isLoading = false }
        do {
            hosts = try SavedListRecovery.load([ServerHost].self, key: storeKey, defaults: defaults) // #482
                .map(hydratingAgentCodes)
        } catch {
            // #482 was: park once without ever attempting recovery.
            LogStore.shared.log(.provisioning,
                "⚠ ServerHostStore: saved VPS list could not be read; original bytes retained for recovery: \(error.localizedDescription)")
        }
        // eoc #482
    }
}
