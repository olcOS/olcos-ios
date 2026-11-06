import Citadel
import Foundation
import UIKit

// MARK: - SSHReadSessions
//
// One open SSH session per server for the read-only status operations (the
// readiness probe, the protocol list, the Xray list), closed `idleSeconds`
// after its last use and when the app goes to the background. A pass over a
// server reads it two or three times in a row, and each read used to log in
// from scratch — a key exchange and an authentication, one to three seconds
// each, more through the tunnel.
//
// Writes never share a session: a failure halfway through a write must not be
// retried on another one. A read that fails on a kept session drops it and
// runs once more on a fresh login — the session may simply have died (the
// tunnel it rode dropped, the server restarted sshd).

@MainActor
final class SSHReadSessions {
    static let shared = SSHReadSessions()

    /// How long a kept session may sit unused before it is closed.
    static let idleSeconds: TimeInterval = 90

    private struct Session {
        let client: SSHRunner.ServerLink
        let relay: SSHTunnelRelay?
        var lastUse: Date
    }

    private var sessions: [String: Session] = [:]
    private var reaper: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    /// Runs `body` on the server's kept session, opening one when there is none.
    func read<T>(host: ServerHost, secret: SSHSecret,
                 _ body: (SSHRunner.ServerLink) async throws -> T) async throws -> T {
        let key = Self.key(host)
        if let kept = sessions[key] {
            do {
                let result = try await body(kept.client)
                sessions[key]?.lastUse = Date()
                return result
            } catch {
                close(key)
                LogStore.shared.log(.provisioning, "↻ SSH: the kept session failed — logging in again")
            }
        }
        let (client, relay) = try await SSHRunner.openConnection(host: host, secret: secret)
        do {
            let result = try await body(client)
            if sessions[key] == nil {
                sessions[key] = Session(client: client, relay: relay, lastUse: Date())
                startReaper()
            } else {
                // Another read opened one meanwhile: keep that, close this.
                Self.shut(client, relay)
            }
            return result
        } catch {
            Self.shut(client, relay)
            throw error
        }
    }

    /// Closes every kept session of `host` — before an operation that changes
    /// how the server is reached (a new key, a reinstall, a reboot).
    func forget(_ host: ServerHost) {
        close(Self.key(host))
    }

    func closeAll() {
        for key in Array(sessions.keys) { close(key) }
    }

    private func close(_ key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        Self.shut(session.client, session.relay)
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let now = Date()
                for (key, session) in self.sessions
                where now.timeIntervalSince(session.lastUse) >= Self.idleSeconds {
                    self.close(key)
                }
                if self.sessions.isEmpty {
                    self.reaper = nil
                    return
                }
            }
        }
    }

    private static func key(_ host: ServerHost) -> String {
        "\(host.id.uuidString)|\(host.host):\(host.port)|\(host.username)"
    }

    private static func shut(_ client: SSHRunner.ServerLink, _ relay: SSHTunnelRelay?) {
        Task {
            await client.close()
            relay?.close()
        }
    }
}
