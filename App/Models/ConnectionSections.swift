import Foundation

/// How the Connections tab sorts connections: the user's own servers first, one
/// group each, in the order the server produced them; then each subscription,
/// holding the servers it brought in; then the links the user added by hand,
/// split by how the traffic travels — inside a video call, or straight to a
/// server (Xray). Protocol records a whole-server connection joins are folded
/// away unless asked for.
struct ConnectionSections: Equatable {
    struct OwnServer: Equatable, Identifiable {
        let id: UUID
        let label: String
        let records: [ConnectionRecord]
    }

    struct Subscription: Equatable, Identifiable {
        /// The key the list's bookkeeping is stored under.
        let source: String
        let records: [ConnectionRecord]
        var id: String { source }
    }

    /// The user's own links through video calls.
    var calls: [ConnectionRecord] = []
    /// The user's own direct links.
    var direct: [ConnectionRecord] = []
    var own: [OwnServer] = []
    var subscriptions: [Subscription] = []
    /// How many records are folded under a whole-server connection.
    var foldedCount = 0

    var isEmpty: Bool {
        calls.isEmpty && direct.isEmpty && own.allSatisfy { $0.records.isEmpty }
            && subscriptions.allSatisfy { $0.records.isEmpty }
    }

    /// PURE. `showFolded` brings back the protocol records a whole-server
    /// connection joins. `subscriptions` are the known list sources, in the
    /// order to show them; a record whose list is not among them (its
    /// bookkeeping lost) stays reachable among the user's own links.
    static func make(records: [ConnectionRecord], hosts: [ServerHost],
                     covered: Set<UUID>, showFolded: Bool,
                     subscriptions sources: [String] = []) -> ConnectionSections {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = ConnectionSections()
        var linked = Set<UUID>()
        for host in hosts {
            let ids = host.linkedConnectionIDs
            linked.formUnion(ids)
            let mine = ids.compactMap { byID[$0] }
            out.own.append(OwnServer(id: host.id, label: host.label,
                                     records: mine.filter { showFolded || !covered.contains($0.id) }))
        }
        // Both link forms of one list are one subscription.
        var slot: [String: Int] = [:]
        var listed: [(source: String, records: [ConnectionRecord])] = []
        for source in sources {
            let canon = ConnectionStore.canonicalSource(source)
            guard slot[canon] == nil else { continue }
            slot[canon] = listed.count
            listed.append((source, []))
        }
        for record in records where !linked.contains(record.id) {
            guard showFolded || !covered.contains(record.id) else { continue }
            if let source = record.subSourceURL, let i = slot[ConnectionStore.canonicalSource(source)] {
                listed[i].records.append(record)
                continue
            }
            switch record.details {
            case .olcrtc: out.calls.append(record)
            case .xray:   out.direct.append(record)
            }
        }
        out.subscriptions = listed.map { Subscription(source: $0.source, records: $0.records) }
        out.foldedCount = records.filter { covered.contains($0.id) }.count
        return out
    }

    /// PURE. Of `records`, how many passed their last check (`working`) and how
    /// many have a verdict at all (`checked`): a list nobody checked yet is not
    /// a list of dead servers.
    static func counts(_ records: [ConnectionRecord],
                       display: (UUID) -> HealthDisplay) -> (working: Int, checked: Int) {
        var working = 0, checked = 0
        for record in records {
            switch display(record.id) {
            case .verified, .fading:
                working += 1
                checked += 1
            case .handshakeOnly, .broken, .inconclusive:
                checked += 1
            case .never, .checking, .stale:
                break
            }
        }
        return (working, checked)
    }

    /// PURE. Direct servers with the working ones first, fastest first, then
    /// the unchecked, then the failing; ties keep the list order. A list of free
    /// servers is long, and the ones worth tapping belong at the top.
    static func byHealth(_ records: [ConnectionRecord],
                         display: (UUID) -> HealthDisplay) -> [ConnectionRecord] {
        func rank(_ d: HealthDisplay) -> (Int, Int) {
            switch d {
            case .verified(let ms, _):             return (0, ms ?? Int.max)
            case .fading(let ms, _):               return (1, ms ?? Int.max)
            case .never, .checking, .stale, .inconclusive: return (2, 0)
            case .handshakeOnly:                   return (3, 0)
            case .broken:                          return (4, 0)
            }
        }
        return records.enumerated()
            .map { (offset: $0.offset, record: $0.element, rank: rank(display($0.element.id))) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
            .map(\.record)
    }
}
