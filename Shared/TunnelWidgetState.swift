import Foundation

// MARK: - TunnelWidgetState
//
// What the widgets and the Control Centre toggle know about the tunnel,
// shared through the App Group that the app, the widget extension and the
// packet-tunnel extension carry. The app writes it on every visible change
// and re-confirms it while a session is engaged; the packet tunnel confirms
// a VPN session it is running, because the app may be suspended for hours
// meanwhile. A widget never claims more than this says: an engaged state that
// nobody re-confirmed within `confirmWindow` is shown as unconfirmed, not as on.
//
// No secrets: a phase, the display names the app already prints on its own
// screens, and dates.
//
// A sideload re-signs the app with the user's own team, and AltStore,
// SideStore and Sideloadly register the App Group under a name of their own,
// so the group this build carries is looked up at run time (`resolvedAppGroup`)
// rather than assumed. Without any App Group there is no shared container:
// every read here returns nil and every write does nothing, and the widget
// falls back to a plain on/off control.

struct TunnelWidgetState: Codable, Equatable, Sendable {

    enum Phase: String, Codable, Sendable {
        case off, connecting, on, waiting, failed

        /// The tunnel is wanted: a toggle should offer "turn off".
        var isEngaged: Bool { self == .connecting || self == .on || self == .waiting }
    }

    var phase: Phase
    /// "Yandex Telemost" / "Xray" — the service the app names on its hero.
    var service: String?
    /// "VP8 · ams-1" — how and where, the hero's second line.
    var route: String?
    /// `TunnelMode` raw value: "vpn" or "proxy".
    var mode: String?
    /// When `.on` began.
    var since: Date?
    /// Last time a process that KNOWS the state wrote or re-confirmed it.
    var confirmedAt: Date
    /// When the current `.connecting` began: the widget draws its progress.
    var startedAt: Date? = nil
    /// The session's traffic so far, already written in the app's language:
    /// "1.2 GB" in and "85 MB" out (one "≈" figure for the in-app proxy's
    /// estimate, `trafficUp` nil then), the last download speed ("4.5 Mbit/s"),
    /// and when they were read.
    var trafficDown: String? = nil
    var trafficUp: String? = nil
    var trafficRate: String? = nil
    var trafficAt: Date? = nil

    static let appGroup = "group.io.github.hotelk52339.olcrtc-ios"
    /// The traffic widget's kind: the app reloads it alone when only the
    /// figures changed.
    static let trafficKind = "io.github.hotelk52339.olcos.widget.traffic"
    static let storageKey = "olcos.widget.tunnel.v1"
    /// The app's language ("en" / "ru" / "fr"), kept apart from the state so
    /// the widget extension can read it on every string lookup cheaply.
    static let languageKey = "olcos.widget.language.v1"
    /// An engaged state not re-confirmed for this long is shown as unconfirmed.
    static let confirmWindow: TimeInterval = 30 * 60
    /// How often a live process re-confirms an engaged state (no widget reload).
    static let confirmInterval: TimeInterval = 10 * 60

    /// The shared defaults, or nil when this build carries no App Group.
    static var sharedDefaults: UserDefaults? {
        resolvedAppGroup.flatMap { UserDefaults(suiteName: $0) }
    }

    /// The App Group this process can open: AltStore and SideStore list the
    /// one they registered in Info.plist (`ALTAppGroups`); the provisioning
    /// profile the build was signed with grants it either way; the name in
    /// the project is the last guess. Ours first when several are granted.
    static let resolvedAppGroup: String? = {
        let bundle = Bundle.main
        var candidates = (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let profile = try? Data(contentsOf: url) {
            candidates += appGroups(inProfile: profile)
        }
        candidates.append(appGroup)
        return orderedAppGroups(candidates).first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }()

    /// PURE. The App Groups a provisioning profile grants: the plist inside
    /// its signature, `Entitlements` → application groups, wildcards dropped.
    static func appGroups(inProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.filter { !$0.contains("*") }
    }

    /// PURE. Each name once, the ones that carry this app's name first.
    static func orderedAppGroups(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0).inserted }
        return unique.filter { $0.contains("olcrtc-ios") } + unique.filter { !$0.contains("olcrtc-ios") }
    }

    static func load(from defaults: UserDefaults? = sharedDefaults) -> TunnelWidgetState? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(TunnelWidgetState.self, from: data)
    }

    /// Writes `state`; false when there is nowhere to write it.
    @discardableResult
    static func save(_ state: TunnelWidgetState, to defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// Is an engaged claim still backed by a recent confirmation?
    func isConfirmed(now: Date) -> Bool {
        let age = now.timeIntervalSince(confirmedAt)
        return age >= -60 && age < Self.confirmWindow
    }

    /// Equal apart from the confirmation stamp — what decides whether a
    /// change is worth reloading the widgets for.
    func sameContent(as other: TunnelWidgetState) -> Bool {
        var a = self, b = other
        a.confirmedAt = .distantPast
        b.confirmedAt = .distantPast
        return a == b
    }

    /// Equal apart from the confirmation stamp and the traffic figures: then
    /// only the traffic widget has something new to draw.
    func sameApartFromTraffic(as other: TunnelWidgetState) -> Bool {
        sameContent(as: other.withTraffic(of: self))
    }

    /// This state with `other`'s traffic figures.
    func withTraffic(of other: TunnelWidgetState) -> TunnelWidgetState {
        var copy = self
        copy.trafficDown = other.trafficDown
        copy.trafficUp = other.trafficUp
        copy.trafficRate = other.trafficRate
        copy.trafficAt = other.trafficAt
        return copy
    }

    // MARK: Packet tunnel side

    /// The VPN the packet tunnel runs came up (`running`) or went away. Keeps
    /// the names the app wrote — the extension has no localized names of its
    /// own. True when the stored phase changed, i.e. a reload is worth it.
    @discardableResult
    static func noteTunnel(running: Bool, now: Date = Date(),
                           defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard let defaults else { return false }
        let previous = load(from: defaults)
        var state = previous ?? TunnelWidgetState(phase: .off, confirmedAt: now)
        if running {
            if state.phase != .on { state.since = now }
            state.phase = .on
            state.mode = "vpn"
        } else {
            state.phase = .off
            state.since = nil
        }
        state.confirmedAt = now
        save(state, to: defaults)
        return previous?.phase != state.phase
    }

    /// Re-confirms an engaged state without changing it (no reload needed).
    static func confirm(now: Date = Date(), defaults: UserDefaults? = sharedDefaults) {
        guard let defaults, var state = load(from: defaults), state.phase.isEngaged else { return }
        state.confirmedAt = now
        save(state, to: defaults)
    }
}
