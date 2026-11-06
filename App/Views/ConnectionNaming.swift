import SwiftUI

// MARK: - ConnectionNaming
//
// ONE composition rule for "what does this connection call itself", read
// by the hero, by the Servers tab's list and by the server cards' protocol
// rows, so the same connection reads identically wherever it appears.
//
// Lives here as a top-level `enum` of pure statics (same shape as
// `ConnectActionSite` in ConnectHero.swift); nothing in it depends on SwiftUI.
//
// WHY IT EXISTS. ONE VPS runs SEVERAL protocol containers, so the identity
// question is "which service am I hiding inside?", not "whose machine".
// `ServersView.recordName` writes "ams-1 · telemost" (the RAW carrier id — a
// persisted token stays locale-stable) into `ConnectionRecord.name`; the
// service's name is drawn from it at render time.
//
// NOTHING HERE REWRITES STORED DATA. `ConnectionRecord.name`,
// `ConnectionDetails.subtitle` (the engineering form the connection log wants)
// and `ServersView.recordName` are untouched: the name links a record to its
// host and is what the user typed. This decides only what views SHOW, at render
// time.
//
// The separator is " · " (U+0020 U+00B7 U+0020) everywhere. Never a comma,
// never an em dash, never a slash.

enum ConnectionNaming {

    /// The SERVICE the traffic hides inside — the identity.
    /// "Yandex Telemost" / "Jitsi" / "WB Stream" / "Xray".
    /// An Xray connection is named by its protocol, as on the server card: the
    /// camouflage site it impersonates read as a website the user is visiting.
    /// A whole-server connection is named for what it is: every service of
    /// the server at once.
    static func service(_ details: ConnectionDetails) -> String {
        switch details {
        case .olcrtc(let p): return p.isBundle ? L10n.bundleServiceName.localized() : service(from: p.carrier)
        case .xray:          return L10n.xrayServiceName.localized()
        }
    }

    /// The same rule from a raw carrier id, for callers that hold one without a
    /// `ConnectionDetails` (the Servers tab's protocol rows).
    static func service(from carrier: String) -> String {
        CarrierTransportMatrix.carrierLabel(carrier)
    }

    /// HOW it is carried — "VP8" / "DataChannel"; for a whole-server
    /// connection, the services it joins and how many rooms.
    static func transport(_ details: ConnectionDetails) -> String {
        switch details {
        case .olcrtc(let p) where p.isBundle:
            return L10n.bundleLanes_fmt.formatted(ServerBundle.servicesLine(p), p.lanes.count)
        case .olcrtc(let p): return CarrierTransportMatrix.transportLabel(p.transport)
        case .xray:          return ProtocolType.xray.label
        }
    }

    /// Both, for one-line venues — "Jitsi · DataChannel".
    static func protocolLine(_ details: ConnectionDetails) -> String {
        "\(service(details)) · \(transport(details))"
    }

    /// The name a list shows: the service for a call protocol ("Yandex
    /// Telemost"), the node's own name for Xray — a list of Xray servers would
    /// otherwise read "Xray" on every row.
    static func listTitle(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc: return service(record.details)
        case .xray:   return record.displayName
        }
    }

    /// Under the server's own name the server goes without saying: the second
    /// line says how the traffic travels instead.
    static func ownServerSubtitle(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc(let p) where p.isBundle: return L10n.listBundleRooms_fmt.formatted(p.lanes.count)
        case .olcrtc:                         return L10n.listViaCallSubtitle.localized()
        case .xray:                           return L10n.listDirectSubtitle.localized()
        }
    }

    /// The quiet second line: which server a call protocol goes to; for Xray,
    /// that it goes there directly.
    static func listSubtitle(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc(let p) where p.isBundle: return L10n.listBundleSubtitle_fmt.formatted(host(record))
        case .olcrtc:                         return host(record)
        case .xray:                           return L10n.listDirectSubtitle.localized()
        }
    }

    /// WHOSE machine — the user's own label for the VPS, with the carrier suffix
    /// `ServersView.recordName` appends removed: the carrier is the headline
    /// above it and no line should say it twice.
    /// "ams-1 · Telemost" → "ams-1".
    ///
    /// Reads `displayName`, not `name`: `displayName` already substitutes
    /// `details.fallbackName` for a blank name, so this can never return "".
    static func host(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc(let p):
            return stripCarrierSuffix(name: record.displayName, carrier: p.carrier)
        case .xray:
            return record.displayName
        }
    }

    /// Does a list of connections span MORE THAN ONE host label?
    ///
    /// With one server the host is the same word on every row, so a list can
    /// leave it out; ask once per change of the list, never inside a `body`.
    ///
    /// Short-circuits on the first disagreement, so the common answer (one host)
    /// still walks the list but the interesting one stops early. An empty list
    /// and a one-record list both span one host, i.e. `false`.
    static func spansMultipleHosts(_ records: [ConnectionRecord]) -> Bool {
        var first: String?
        for record in records {
            let label = host(record)
            if let first {
                if first != label { return true }
            } else {
                first = label
            }
        }
        return false
    }

    /// The pure, testable core of `host`. Conservative by construction: it
    /// strips ONLY when the trailing segment really is this record's carrier,
    /// and returns the name untouched in every other case — a user who named
    /// their server "prod · Frankfurt" keeps both halves.
    ///
    /// 1. trim the name;
    /// 2. find the LAST " · "; no separator ⇒ return the trimmed name;
    /// 3. an empty prefix ⇒ return the trimmed name (never return "");
    /// 4. compare the tail, normalised (lowercased, letters and digits only, so
    ///    "WB Stream" ≡ "wbstream"), against the raw carrier id AND its current
    ///    localized label; strip on a match, otherwise leave the name alone.
    static func stripCarrierSuffix(name: String, carrier: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = trimmed.range(of: " · ", options: .backwards) else { return trimmed }
        let prefix = String(trimmed[trimmed.startIndex..<sep.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return trimmed }
        let tail = normalizeForMatch(String(trimmed[sep.upperBound...]))
        guard !tail.isEmpty else { return trimmed }
        let candidates = [normalizeForMatch(carrier),
                          normalizeForMatch(CarrierTransportMatrix.carrierLabel(carrier))]
        if candidates.contains(tail) { return prefix }
        // Migration allowance: names are stamped with the label that was current
        // WHEN THE RECORD WAS CREATED, and labels have changed since ("Telemost"
        // → "Yandex Telemost"). A stored «ams-1 · Телемост» must still strip. The
        // 5-character floor keeps a short user word from matching by accident.
        if tail.count >= 5, candidates.contains(where: { $0.hasSuffix(tail) }) { return prefix }
        return trimmed
    }

    /// Case- and punctuation-insensitive comparison key. Deliberately keeps
    /// non-Latin letters ("Телемост" → "телемост") — the labels are localized.
    private static func normalizeForMatch(_ text: String) -> String {
        let kept: String = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return kept
    }
}
