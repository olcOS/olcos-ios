import Foundation

// MARK: - ServerControl
//
// How the app reaches the servers it manages for the jobs the HTTPS agent does
// (status, starting and stopping rooms, live updates on the server screen).
// Automatic tries the agent and reads over SSH when it does not answer; the two
// HTTPS choices use one route each and show a failure instead of hiding it
// behind SSH; SSH never touches the agent, nor installs it. Installing the
// agent, adding rooms, updates and logs go over SSH whatever is chosen.

enum ServerControl: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case httpsTunnel
    case httpsDirect
    case ssh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:        return L10n.serverControlAuto.localized()
        case .httpsTunnel: return L10n.serverControlHTTPSTunnel.localized()
        case .httpsDirect: return L10n.serverControlHTTPSDirect.localized()
        case .ssh:         return L10n.serverControlSSH.localized()
        }
    }

    /// The note under the picker, for the chosen way.
    var hint: String {
        switch self {
        case .auto:        return L10n.serverControlAutoHint.localized()
        case .httpsTunnel: return L10n.serverControlHTTPSTunnelHint.localized()
        case .httpsDirect: return L10n.serverControlHTTPSDirectHint.localized()
        case .ssh:         return L10n.serverControlSSHHint.localized()
        }
    }

    var usesAgent: Bool { self != .ssh }

    /// A failed agent call quietly becomes an SSH one only on Automatic.
    var fallsBackToSSH: Bool { self == .auto }
}
