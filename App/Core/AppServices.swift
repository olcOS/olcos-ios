import Foundation

// MARK: - AppServices
//
// The app-wide objects a connection needs, built once per process.
//
// MainTabView used to build them in its own initializer, which runs only when
// a window exists. A widget, the Control Centre toggle or CarPlay can launch
// the app in the BACKGROUND, with no window, to switch the tunnel
// (`TunnelRemoteControl`). Both paths now take the same instances from here,
// so a session started from the Lock Screen is the one the app shows when it
// is opened, and there is never a second TunnelManager in the process.
//
// Views still receive these by initializer (MainTabView wraps them in
// `@StateObject`); nothing in the view tree reads `AppServices.shared`.

@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: ConnectionStore
    let serverStore: ServerHostStore
    let tunnel: TunnelManager
    /// Renews a Telemost room before its 24 h clock runs out; needs all three
    /// stores, and must hold the same TunnelManager as everything else.
    let telemostRenewal: TelemostRenewalCoordinator
    /// Replaces VK Calls, SaluteJazz, MTS Link and Jitsi rooms on the schedule
    /// the user set for each protocol, and runs the silent daily account check;
    /// same ownership reason as the Telemost renewal.
    let roomRotation: RoomRotationCoordinator
    /// Mirrors the tunnel into the shared state the widgets read.
    let widgetState: TunnelWidgetPublisher
    /// The live session on the Lock Screen and in the Dynamic Island.
    let liveActivity: TunnelLiveActivityPublisher
    /// Keeps the lists behind device invites current on their servers.
    let inviteSync: InviteSync
    /// Keeps each server's whole-server connection and bond endpoint current.
    let bundleSync: BundleSync
    /// Which of the user's servers run another core than this app speaks.
    let coreWatch: CoreVersionWatch
    /// Held here rather than as root `@StateObject`s: the root only hands them
    /// to the screens that observe them, so it must not re-render on their
    /// changes (a running speed test publishes many times a second).
    let ipCheck = IPChecker()
    let speed = SpeedTest()

    private init() {
        LegacyAccountCleanup.removeAll()
        let store = ConnectionStore()
        // The failover provider captures both stores: the sibling protocols to
        // fail over to are the records a ServerHost links (last + extra).
        let serverStore = ServerHostStore()
        let tunnel = TunnelManager(
            secretsLocked: { [weak store] in
                store?.secretsLocked ?? false
            },
            failoverCandidates: { [weak store, weak serverStore] current in
                TunnelManager.computeFailoverCandidates(current, store: store, serverStore: serverStore)
            })
        self.store = store
        self.serverStore = serverStore
        self.tunnel = tunnel
        telemostRenewal = TelemostRenewalCoordinator(connections: store, tunnel: tunnel, hosts: serverStore)
        roomRotation = RoomRotationCoordinator(connections: store, hosts: serverStore, tunnel: tunnel)
        widgetState = TunnelWidgetPublisher(tunnel: tunnel, store: store)
        liveActivity = TunnelLiveActivityPublisher(tunnel: tunnel, store: store)
        inviteSync = InviteSync(connections: store, hosts: serverStore)
        bundleSync = BundleSync(connections: store, hosts: serverStore)
        coreWatch = CoreVersionWatch(hosts: serverStore)
        // A protocol whose container the last listing found stopped is not
        // checked, and its old verdict counts for nothing.
        HealthCoordinator.shared.stoppedRecords = { [weak store, weak serverStore] in
            guard let store, let serverStore else { return [] }
            return HealthCoordinator.shared.stoppedRecordIDs(hosts: serverStore.hosts, records: store.connections)
        }
        // A reconnect dials the record as it is saved now, not as it connected.
        tunnel.currentRecord = { [weak store] id in
            store?.connections.first { $0.id == id }
        }
        // A lane of the live session that stays dead: where are its rooms now?
        let bundleSync = self.bundleSync
        tunnel.refreshLiveRecord = { [weak store, weak serverStore, weak bundleSync] record in
            guard let store, let serverStore, let bundleSync else { return nil }
            return await LiveRecordRefresh.refresh(record, store: store, hosts: serverStore, bundleSync: bundleSync)
        }
    }
}
