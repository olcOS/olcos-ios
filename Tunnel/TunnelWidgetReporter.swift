import Foundation

/// Tells the widgets what the VPN this extension runs is doing. The app may be
/// suspended for hours while the tunnel is up, so this process is the one that
/// knows: it marks the session up once the routes are installed, re-confirms it
/// every `TunnelWidgetState.confirmInterval` and marks it off on teardown.
///
/// It only WRITES the shared state. Asking WidgetKit to reload from here would
/// link SwiftUI into a process that lives under a ~50 MB memory ceiling; the
/// widget re-reads the state on its own schedule instead (TunnelStatusProvider),
/// and the app reloads it whenever the app is running.
/// Without the App Group (a free-account sideload) every call is a no-op.
/// All calls arrive on the provider's work queue.
final class TunnelWidgetReporter {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func tunnelUp() {
        TunnelWidgetState.noteTunnel(running: true)
        timer?.cancel()
        timer = nil
        guard TunnelWidgetState.sharedDefaults != nil else { return }
        let interval = TunnelWidgetState.confirmInterval
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { TunnelWidgetState.confirm() }
        source.resume()
        timer = source
    }

    func tunnelDown() {
        timer?.cancel()
        timer = nil
        TunnelWidgetState.noteTunnel(running: false)
    }
}
