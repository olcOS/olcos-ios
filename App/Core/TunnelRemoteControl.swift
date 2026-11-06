import UIKit

// MARK: - TunnelRemoteControl
//
// The app side of the widget / Control Centre / CarPlay intents
// (Shared/TunnelControlIntents.swift). They run in this process, often after
// a background launch with no window, so everything goes through
// `AppServices.shared` — the same objects the UI uses once it appears.
//
// Before deciding anything it adopts a tunnel that is already running (the
// app may have been launched cold into a live VPN session), so "turn on"
// never starts a second client next to one that is up.

@MainActor
enum TunnelRemoteControl {

    /// How long `perform()` waits for a start to leave `.connecting`, so the
    /// widget reload that follows shows the outcome rather than the request.
    static let settleSeconds: Double = 8
    /// How long a start may keep the app awake after `perform()` returns.
    /// VPN mode no longer needs the app once the system tunnel is starting;
    /// the in-app proxy does, until it is verified and the keep-alive (when
    /// enabled) takes over.
    static let backgroundBudgetSeconds: Double = 25

    static func set(running: Bool) async throws {
        let services = AppServices.shared
        let tunnel = services.tunnel
        await tunnel.vpn.adoptRunningTunnel()
        if running {
            if tunnel.engagedRecord == nil {
                guard let record = services.store.primary else { throw TunnelIntentError.noConnection }
                guard !services.store.secretsLocked else { throw TunnelIntentError.secretsLocked }
                let awake = BackgroundAssertion(name: "olcOS connect")
                tunnel.connect(record: record)
                await settle(tunnel, upTo: settleSeconds)
                awake.release(after: tunnel.state == .connecting ? backgroundBudgetSeconds : 0)
            }
        } else if tunnel.state != .disconnected {
            tunnel.disconnect()
        }
        services.widgetState.publish()
    }

    static func toggle() async throws {
        let tunnel = AppServices.shared.tunnel
        await tunnel.vpn.adoptRunningTunnel()
        try await set(running: tunnel.engagedRecord == nil)
    }

    private static func settle(_ tunnel: TunnelManager, upTo seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while tunnel.state == .connecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Keeps a background-launched app running for a bounded time, so a start
/// begun from a widget is not frozen half-way. Ended exactly once.
@MainActor
private final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        // UIKit calls the expiration handler on the main thread.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func release(after seconds: Double) {
        guard seconds > 0 else { end(); return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(seconds))
            end()
        }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
