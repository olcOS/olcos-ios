import WidgetKit
import SwiftUI
import AppIntents

// MARK: - TunnelControlWidget (iOS 18)
//
// One toggle for Control Centre, the Lock Screen and the Action button. It is
// on only while the shared state says the tunnel is wanted AND a process that
// knows confirmed it recently — the rule the widget draws by. Flipping it
// sends `SetTunnelRunningIntent`, which the app runs.

@available(iOS 18.0, *)
struct TunnelControlWidget: ControlWidget {
    static let kind = "io.github.hotelk52339.olcos.control.tunnel"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: TunnelControlValue()) { isOn in
            ControlWidgetToggle("olcOS", isOn: isOn, action: SetTunnelRunningIntent()) { isOn in
                Label(isOn ? L10n.stateConnected.localized() : L10n.stateDisconnected.localized(),
                      systemImage: isOn ? "network" : "network.slash")
            }
        }
        .displayName("olcOS")
        // Registered with the system as a resource; the interpolation carries
        // the app's own translation through, since there is no strings table.
        .description("\(L10n.controlDescription.localized())")
    }
}

@available(iOS 18.0, *)
struct TunnelControlValue: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let state = TunnelWidgetState.load() else { return false }
        return state.phase.isEngaged && state.isConfirmed(now: Date())
    }
}
