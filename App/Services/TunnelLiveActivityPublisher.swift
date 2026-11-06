import ActivityKit
import Combine
import Foundation
import UIKit

// MARK: - TunnelLiveActivityPublisher
//
// Puts the live session on the Lock Screen and in the Dynamic Island
// (Settings → Live Activity, on by default): one Live Activity from the moment
// a session is wanted until it ends, fed every couple of seconds with the
// state, the server and the measured speed. It needs no App Group — the app
// hands the system every word and figure — so it works however the app was
// installed. iOS lets only an app on screen START one: a session that comes
// up in the background gets its card the next time the app opens.

@MainActor
final class TunnelLiveActivityPublisher {
    /// The shortest gap between two updates of the same phase.
    static let updateGap: TimeInterval = 2
    /// A card nobody updated for this long reads as out of date.
    static let staleAfter: TimeInterval = 300

    private let tunnel: TunnelManager
    private let store: ConnectionStore
    /// Samples at the card's own pace (`updateGap`): the card cannot show more
    /// than one reading per gap, and this monitor keeps running in the
    /// background while the session lasts.
    private let monitor = TunnelThroughputMonitor(interval: .seconds(2))
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<TunnelActivityAttributes>?
    private var since: Date?
    private var history: [Double] = []
    private var lastSent: TunnelActivityAttributes.ContentState?
    private var lastSentAt = Date.distantPast
    /// The user swiped the card away: it stays away until the session ends.
    private var dismissedByUser = false
    private var stateWatch: Task<Void, Never>?

    init(tunnel: TunnelManager, store: ConnectionStore) {
        self.tunnel = tunnel
        self.store = store
        // `objectWillChange` fires BEFORE the new values land: act a turn later.
        tunnel.objectWillChange
            .merge(with: SettingsStore.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        monitor.$reading
            .dropFirst()
            .sink { [weak self] reading in self?.noteReading(reading) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    /// Starts, feeds or ends the card to match the tunnel and the setting.
    func sync() {
        let phase = TunnelWidgetPublisher.phase(for: tunnel.state, recovering: tunnel.hasPendingRecovery)
        if !phase.isEngaged { dismissedByUser = false }
        let wanted = SettingsStore.shared.liveActivity && phase.isEngaged && !dismissedByUser
        // The speed is measured only while a session is up and the card is wanted.
        monitor.update(isConnected: tunnel.state.isConnected, isOnScreen: wanted, sceneIsActive: true,
                       mode: tunnel.activeMode, vpn: tunnel.vpn,
                       laneNames: LaneReading.names(of: tunnel.connectedRecord,
                                                    inVPN: tunnel.activeMode == .vpn))
        guard wanted else {
            endAll()
            return
        }
        if phase == .on {
            if since == nil { since = Date() }
        } else {
            since = nil
            history = []
        }
        let state = content(phase: phase)
        if activity == nil {
            start(state)
        } else {
            send(state)
        }
    }

    // MARK: Content

    private func noteReading(_ reading: ThroughputReading?) {
        guard activity != nil, tunnel.state.isConnected else { return }
        if let reading {
            history = TunnelActivityContent.appending(Self.down(reading), to: history)
        }
        send(content(phase: .on))
    }

    private func content(phase: TunnelWidgetState.Phase) -> TunnelActivityAttributes.ContentState {
        let record = tunnel.connectedRecord ?? tunnel.engagedRecord ?? store.primary
        let reading = phase == .on ? monitor.reading : nil
        let down = reading.map(Self.down)
        let up: Double? = {
            if case .exact(_, let out)? = reading { return out }
            return nil
        }()
        return TunnelActivityAttributes.ContentState(
            phase: phase.rawValue,
            headline: Self.headline(phase),
            detail: record.map { "\(ConnectionNaming.listTitle($0)) · \(ConnectionNaming.host($0))" }
                ?? TunnelWidgetDisplay.brand,
            since: phase == .on ? since : nil,
            down: down.map { ThroughputFormat.bits($0) } ?? "",
            up: up.map { ThroughputFormat.bits($0) } ?? "",
            downShort: down.map { ThroughputFormat.bitsShort($0) } ?? "",
            history: history)
    }

    /// The download, or the one figure an estimate has.
    private static func down(_ reading: ThroughputReading) -> Double {
        switch reading {
        case .exact(let inBytes, _): return inBytes
        case .estimate(let total):   return total
        }
    }

    private static func headline(_ phase: TunnelWidgetState.Phase) -> String {
        switch phase {
        case .on:         return L10n.stateConnected.localized()
        case .connecting: return L10n.stateConnecting.localized()
        case .waiting:    return L10n.stateWaitingForNetwork.localized()
        case .failed:     return L10n.widgetStateFailed.localized()
        case .off:        return L10n.stateDisconnected.localized()
        }
    }

    // MARK: The card

    private func start(_ state: TunnelActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // One left up by an earlier run of the app is carried on, not doubled.
        if let existing = Activity<TunnelActivityAttributes>.activities.first {
            activity = existing
            watch(existing)
            send(state, force: true)
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            activity = try Activity.request(
                attributes: TunnelActivityAttributes(),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: nil)
            lastSent = state
            lastSentAt = Date()
            if let activity { watch(activity) }
        } catch {
            LogStore.shared.log(.connection, "Live Activity not started: \(error.localizedDescription)")
        }
    }

    /// At most every `updateGap` while the phase holds; at once when it changes.
    private func send(_ state: TunnelActivityAttributes.ContentState, force: Bool = false) {
        guard let activity, force || state != lastSent else { return }
        let now = Date()
        let phaseChanged = state.phase != lastSent?.phase
        guard force || phaseChanged || now.timeIntervalSince(lastSentAt) >= Self.updateGap else { return }
        lastSent = state
        lastSentAt = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    /// Notices the user swiping the card off the Lock Screen. Our own end
    /// cancels this first, so it is never mistaken for the user's.
    private func watch(_ card: Activity<TunnelActivityAttributes>) {
        stateWatch?.cancel()
        stateWatch = Task { @MainActor [weak self] in
            for await state in card.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed {
                    self?.dismissedByUser = true
                    self?.activity = nil
                    self?.sync()
                    return
                }
                if state == .ended { return }
            }
        }
    }

    private func endAll() {
        stateWatch?.cancel()
        stateWatch = nil
        since = nil
        history = []
        lastSent = nil
        activity = nil
        let open = Activity<TunnelActivityAttributes>.activities
        guard !open.isEmpty else { return }
        Task {
            for card in open { await card.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
