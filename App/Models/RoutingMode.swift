import Foundation

// MARK: - RoutingMode
//
// Settings → Routing: whether every site goes through the tunnel, or the
// sites on a list go straight out while the rest go through it. The list is
// the ready-made Russian one and the user's own (DirectRoutes); the engines
// take it as one text (EngineStartSettings.directRules). The raw values are
// persisted (`settings.routingMode`).

enum RoutingMode: String, CaseIterable, Identifiable, Sendable {
    case allTunnel
    case listDirect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTunnel:  return L10n.routingAllTunnel.localized()
        case .listDirect: return L10n.routingListDirect.localized()
        }
    }
}
