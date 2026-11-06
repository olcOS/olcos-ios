import Foundation
import Combine
import UIKit
import WidgetKit

// MARK: - TunnelWidgetPublisher
//
// Mirrors the tunnel into `TunnelWidgetState` for the widgets and the
// Control Centre toggle. It writes when what a widget would draw changes and
// reloads the widgets then; while a session is engaged it also re-confirms the
// stored state every `confirmInterval` WITHOUT a reload, so a widget can tell
// a session that is still up from one whose app was killed hours ago.
//
// While a session is up it also measures what the session moved, slowly,
// for the traffic widget. Only the figures changing reloads that widget
// alone, at most once a minute while the app is open and once a quarter hour
// in the background, where iOS rations widget reloads for the whole day.
//
// A build without the App Group has nowhere to write; the publisher then does
// nothing at all.

@MainActor
final class TunnelWidgetPublisher {
    private let tunnel: TunnelManager
    private let store: ConnectionStore
    private var cancellables = Set<AnyCancellable>()
    private var last: TunnelWidgetState?
    private var onSince: Date?
    private var connectingSince: Date?
    private var confirmTask: Task<Void, Never>?
    /// The session's traffic for the traffic widget, sampled slowly.
    private let monitor = TunnelThroughputMonitor(interval: .seconds(15))
    private var lastTrafficReload = Date.distantPast

    init(tunnel: TunnelManager, store: ConnectionStore) {
        self.tunnel = tunnel
        self.store = store
        guard TunnelWidgetState.sharedDefaults != nil else { return }
        // `objectWillChange` fires BEFORE the new values land, so the publish
        // is deferred to the next main-queue turn, and coalesced there.
        tunnel.objectWillChange
            .merge(with: store.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        monitor.$sessionBytes
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        publish()
    }

    /// Writes the current state when it differs from what the widgets show.
    func publish() {
        guard let defaults = TunnelWidgetState.sharedDefaults else { return }
        let phase = Self.phase(for: tunnel.state, recovering: tunnel.hasPendingRecovery)
        if phase == .on {
            if last?.phase != .on { onSince = Date() }
        } else {
            onSince = nil
        }
        if phase == .connecting {
            if last?.phase != .connecting { connectingSince = Date() }
        } else {
            connectingSince = nil
        }
        monitor.update(isConnected: phase == .on, isOnScreen: true, sceneIsActive: true,
                       mode: tunnel.activeMode, vpn: tunnel.vpn)
        let record = tunnel.engagedRecord ?? store.primary
        let mode = phase == .off || phase == .failed ? tunnel.effectiveModeForNextConnection : tunnel.activeMode
        var next = TunnelWidgetState(
            phase: phase,
            service: record.map { ConnectionNaming.service($0.details) },
            route: record.map(Self.route),
            mode: mode.rawValue,
            since: onSince,
            confirmedAt: Date(),
            startedAt: connectingSince)
        if phase == .on, let moved = monitor.sessionBytes {
            next.trafficDown = (moved.exact ? "" : "≈ ") + Self.bytes(moved.down)
            next.trafficUp = moved.exact ? Self.bytes(moved.up) : nil
            next.trafficRate = monitor.reading.map { ThroughputFormat.bits($0.totalBytesPerSecond) }
            next.trafficAt = Date()
        }
        defaults.set(SettingsStore.shared.language, forKey: TunnelWidgetState.languageKey)
        if let last, last.sameContent(as: next) { return }
        let onlyTraffic = last?.sameApartFromTraffic(as: next) ?? false
        last = next
        TunnelWidgetState.save(next, to: defaults)
        if onlyTraffic {
            reloadTrafficIfDue()
            return
        }
        lastTrafficReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        keepConfirming(phase.isEngaged)
    }

    /// The second line: how and where. A whole-server connection says how
    /// many rooms, not every service it joins (that does not fit a widget).
    private static func route(_ record: ConnectionRecord) -> String {
        if case .olcrtc(let p) = record.details, p.isBundle {
            return "\(L10n.bundleRooms_fmt.formatted(p.lanes.count)) · \(ConnectionNaming.host(record))"
        }
        return "\(ConnectionNaming.transport(record.details)) · \(ConnectionNaming.host(record))"
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    /// Only the figures changed: the traffic widget, if a reload is due.
    private func reloadTrafficIfDue() {
        let gap: TimeInterval = UIApplication.shared.applicationState == .active ? 60 : 15 * 60
        guard Date().timeIntervalSince(lastTrafficReload) >= gap else { return }
        lastTrafficReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: TunnelWidgetState.trafficKind)
    }

    /// The widget phase for a tunnel state. A failure the manager is still
    /// recovering from is a connection in progress, not a verdict.
    nonisolated static func phase(for state: ConnectionState, recovering: Bool) -> TunnelWidgetState.Phase {
        switch state {
        case .disconnected:      return .off
        case .connecting:        return .connecting
        case .connected:         return .on
        case .waitingForNetwork: return .waiting
        case .failed:            return recovering ? .connecting : .failed
        }
    }

    private func keepConfirming(_ engaged: Bool) {
        guard engaged else {
            confirmTask?.cancel()
            confirmTask = nil
            return
        }
        guard confirmTask == nil else { return }
        confirmTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TunnelWidgetState.confirmInterval))
                guard !Task.isCancelled, let self else { return }
                guard var state = self.last, state.phase.isEngaged else {
                    self.confirmTask = nil
                    return
                }
                state.confirmedAt = Date()
                self.last = state
                TunnelWidgetState.save(state)
            }
        }
    }
}
