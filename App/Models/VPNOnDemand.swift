import Foundation
#if canImport(NetworkExtension)
import NetworkExtension
#endif

// MARK: - VPN auto-connect
//
// Settings → Auto-connect: iOS turns the VPN on by itself on mobile data, on
// any Wi-Fi, only on the networks listed, or everywhere except them (trusted
// networks, where it turns the VPN off). Nothing here ever turns the VPN off
// on a network the user did not name. The rules ride the saved VPN profile,
// so iOS can start the tunnel while the app is closed — which is why a
// profile with auto-connect on keeps its connection key after a session
// (VPNController.scrubStoredSecrets), and why turning the VPN off by hand
// pauses auto-connect until it is turned on again.

enum WiFiAutoConnect: String, CaseIterable, Identifiable, Sendable {
    case off, any, only, except

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return L10n.autoConnectWiFiOff.localized()
        case .any:    return L10n.autoConnectWiFiAny.localized()
        case .only:   return L10n.autoConnectWiFiOnly.localized()
        case .except: return L10n.autoConnectWiFiExcept.localized()
        }
    }

    /// The modes that need a list of networks.
    var takesNetworks: Bool { self == .only || self == .except }
}

/// What iOS is told, decided in one pure place.
enum VPNOnDemandPlan {
    struct Rule: Equatable, Sendable {
        enum Action: Equatable, Sendable { case connect, disconnect, ignore }
        enum Interface: Equatable, Sendable { case wifi, cellular, any }

        var action: Action
        var interface: Interface
        var networks: [String] = []
    }

    /// PURE. The rules for the settings, in iOS's order (first match wins);
    /// nil when nothing would turn the VPN on — auto-connect is then off.
    static func rules(cellular: Bool, wifi: WiFiAutoConnect, networks: [String]) -> [Rule]? {
        let names = cleaned(networks)
        var rules: [Rule] = []
        switch wifi {
        case .off:
            break
        case .any:
            rules.append(Rule(action: .connect, interface: .wifi))
        case .only:
            if !names.isEmpty { rules.append(Rule(action: .connect, interface: .wifi, networks: names)) }
        case .except:
            if !names.isEmpty { rules.append(Rule(action: .disconnect, interface: .wifi, networks: names)) }
            rules.append(Rule(action: .connect, interface: .wifi))
        }
        if cellular {
            rules.append(Rule(action: .connect, interface: .cellular))
        }
        guard rules.contains(where: { $0.action == .connect }) else { return nil }
        // Everywhere else the VPN stays as it is.
        rules.append(Rule(action: .ignore, interface: .any))
        return rules
    }

    /// PURE. The networks as typed, one per line: trimmed, each once.
    static func cleaned(_ networks: [String]) -> [String] {
        var seen = Set<String>()
        return networks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

#if canImport(NetworkExtension)
extension VPNOnDemandPlan.Rule {
    /// The rule as iOS takes it.
    var system: NEOnDemandRule {
        let rule: NEOnDemandRule
        switch action {
        case .connect:    rule = NEOnDemandRuleConnect()
        case .disconnect: rule = NEOnDemandRuleDisconnect()
        case .ignore:     rule = NEOnDemandRuleIgnore()
        }
        switch interface {
        case .wifi:     rule.interfaceTypeMatch = .wiFi
        case .cellular: rule.interfaceTypeMatch = .cellular
        case .any:      rule.interfaceTypeMatch = .any
        }
        if !networks.isEmpty { rule.ssidMatch = networks }
        return rule
    }
}
#endif
