import Foundation

/// The DNS setting as each consumer needs it. The user picks one resolver; the
/// core on the phone and everything on the VPS each get the form of it that
/// works where they run.
enum DNSChoice {
    /// The resolvers the core itself falls back between when the chosen one
    /// stays silent (olcrtc-upstream internal/protect/resolver.go, `dnsIPv6Peer`).
    static let publicOperatorHosts: Set<String> = [
        "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
    ]

    /// For the core on the phone: the choice first, then Cloudflare behind any
    /// resolver the core does not know. The core puts the other public
    /// resolvers behind a public one that stays silent, but behind Yandex or a
    /// carrier resolver it had only the system resolver, after a timeout on
    /// every lookup — a room start on SaluteJazz or Telemost ran out of time
    /// that way.
    static func forPhoneCore(_ dns: String) -> String {
        let chosen = VPNConfig.host(of: dns)
        guard !chosen.isEmpty, !publicOperatorHosts.contains(chosen) else { return dns }
        return dns + "," + SettingsStore.Defaults.dnsServer
    }

    /// For what runs on the VPS (server.yaml, the bond endpoint) and for the
    /// system resolver in VPN mode, which is asked through the tunnel and so
    /// from the VPS too: a mobile carrier's resolver answers only inside that
    /// carrier's network, so it becomes the default public one. Compared by
    /// host, so a hand-typed preset without a port matches.
    static func forServer(_ dns: String) -> String {
        let chosen = VPNConfig.host(of: dns)
        let carrierInternal = AppConstants.ruCarrierDnsPresets.contains { VPNConfig.host(of: $0.value) == chosen }
        return carrierInternal ? SettingsStore.Defaults.dnsServer : dns
    }
}
