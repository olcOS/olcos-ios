import Foundation

// MARK: - TunnelWidgetDisplay
//
// What a widget draws for a `TunnelWidgetState`, decided in one pure place so
// the app's tests can pin it: the tone, the headline, the second line and
// which action the button offers. Compiled into the app (for the tests) and
// into the widget extension (which draws it).
//
// The button never guesses. With a known state it says what it will do
// ("Turn off" while engaged, "Turn on" otherwise) and sends that exact value;
// with no state, or an engaged state nobody re-confirmed, it offers a plain
// toggle, and the app — which knows — decides.

enum TunnelWidgetDisplay {

    enum Tone: Equatable { case off, busy, on, problem, unknown }

    enum Action: Equatable {
        case turnOn, turnOff, toggle
    }

    struct Model: Equatable {
        var tone: Tone
        var headline: String
        var detail: String?
        var action: Action
        /// Count up from here (the session's start) when on.
        var since: Date?
        /// "VPN" / "Proxy", when the state says which backend.
        var mode: String?
        /// When a connection in progress began: the widget fills a bar from here.
        var startedAt: Date?
    }

    /// How long the connecting bar takes to fill: most sessions are up by then.
    static let connectBudget: TimeInterval = 30

    static func model(for state: TunnelWidgetState?, now: Date) -> Model {
        guard let state else {
            return Model(tone: .unknown, headline: brand,
                         detail: L10n.widgetHintToggle.localized(), action: .toggle)
        }
        let route = [state.service, state.route].compactMap { $0 }.joined(separator: " · ")
        let detail = route.isEmpty ? nil : route
        let mode = modeLabel(state.mode)
        if state.phase.isEngaged, !state.isConfirmed(now: now) {
            return Model(tone: .unknown, headline: L10n.widgetStateUnknown.localized(),
                         detail: L10n.widgetHintOpenApp.localized(), action: .toggle)
        }
        switch state.phase {
        case .off:
            return Model(tone: .off, headline: L10n.stateDisconnected.localized(),
                         detail: detail ?? L10n.widgetHintNoConnection.localized(),
                         action: .turnOn, mode: mode)
        case .connecting:
            return Model(tone: .busy, headline: L10n.stateConnecting.localized(),
                         detail: detail, action: .turnOff, mode: mode, startedAt: state.startedAt)
        case .on:
            return Model(tone: .on, headline: L10n.stateConnected.localized(),
                         detail: detail, action: .turnOff, since: state.since, mode: mode)
        case .waiting:
            return Model(tone: .busy, headline: L10n.stateWaitingForNetwork.localized(),
                         detail: detail, action: .turnOff, mode: mode)
        case .failed:
            return Model(tone: .problem, headline: L10n.widgetStateFailed.localized(),
                         detail: detail, action: .turnOn, mode: mode)
        }
    }

    /// The button's words for an action.
    static func title(for action: Action) -> String {
        switch action {
        case .turnOn:  return L10n.widgetActionOn.localized()
        case .turnOff: return L10n.widgetActionOff.localized()
        case .toggle:  return L10n.widgetActionToggle.localized()
        }
    }

    /// The product name. A name, not a sentence, so it is not translated.
    static let brand = "olcOS"

    private static func modeLabel(_ raw: String?) -> String? {
        switch raw {
        case "vpn":   return L10n.tunnelModeVPN.localized()
        case "proxy": return L10n.tunnelModeProxy.localized()
        default:      return nil
        }
    }
}
