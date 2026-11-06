import Foundation

// MARK: - CoreVersionWatch
//
// The tunnel protocol has no version check of its own: a server on another
// core commit than the app's pin lets a session connect and then drops it
// within minutes. Once per run of the app this asks each of the user's
// servers which commit it runs (one short read-only SSH command) and keeps
// the ones that differ, so Home can say so and lead to My servers, where the
// server screen updates a stale core by itself (`ServersView.updateIfStale`).
// The server screen reports every commit it reads here too, so the notice
// goes away as soon as an update lands.

@MainActor
final class CoreVersionWatch: ObservableObject {
    @Published private(set) var staleHostIDs: Set<UUID> = []

    private let hosts: ServerHostStore
    private var checked = false

    init(hosts: ServerHostStore) {
        self.hosts = hosts
    }

    func checkOnce() {
        guard !checked else { return }
        checked = true
        for host in hosts.hosts {
            guard let container = host.lastContainerName, let secret = hosts.secret(for: host) else { continue }
            Task {
                let commit = try? await SSHRunner.coreCommit(host: host, secret: secret, containerName: container)
                self.note(hostID: host.id, commit: commit)
            }
        }
    }

    /// What a server reported; an unknown commit changes nothing.
    func note(hostID: UUID, commit: String?) {
        guard let current = SSHRunner.coreIsCurrent(commit) else { return }
        if current {
            staleHostIDs.remove(hostID)
        } else {
            staleHostIDs.insert(hostID)
        }
    }
}
