import SwiftUI   // for OlcStatusTone (defined in App/UI/DesignSystem.swift)

// MARK: - ProtocolStanding
//
// One question, asked the same way of a protocol, a room, a whole-server
// connection and the server card above them: can it be used now? The answer is
// read from the latest evidence (`HealthDisplay`), with the same freshness
// rules everywhere:
//   • working   — a verified check, or a good one within the last 30 minutes
//                 that nothing has contradicted since (`.fading`);
//   • failed    — the last check ran and found a fault;
//   • unchecked — never checked, could not be checked, or too old to rely on;
//   • stopped   — its container is not running: it is not checked, and an
//                 old verdict about it says nothing about now.
// Only `failed` is a bad word. An unchecked protocol is not a broken one.

enum ProtocolStanding: Equatable, Sendable {
    case working, failed, unchecked, stopped

    init(_ display: HealthDisplay) {
        switch display {
        case .verified, .fading:
            self = .working
        case .broken, .handshakeOnly:
            self = .failed
        case .never, .checking, .inconclusive, .stale:
            self = .unchecked
        }
    }

    var tone: OlcStatusTone {
        switch self {
        case .working:   return .ok
        case .failed:    return .error
        case .unchecked: return .unknown
        case .stopped:   return .unknown
        }
    }

    /// The server card's headline word for this standing.
    var title: String {
        switch self {
        case .working:   return L10n.healthVerified.localized()
        case .failed:    return L10n.listWordNotWorking.localized()
        case .unchecked: return L10n.healthChipNotChecked.localized()
        case .stopped:   return L10n.protocolStopped.localized()
        }
    }
}

extension HealthDisplay {
    var standing: ProtocolStanding { ProtocolStanding(self) }

    /// What a connection shows while the live tunnel runs through it. The
    /// tunnel's own traffic and keep-alive checks are the freshest evidence
    /// there is, so an older verdict of any kind (a failure from before it
    /// connected, "not checked") gives way to it; a measured round trip is
    /// kept.
    func carryingLiveTunnel() -> HealthDisplay {
        switch self {
        case .verified:
            return self
        case .fading(let ms, _):
            return .verified(ms: ms, age: 0)
        case .never, .checking, .handshakeOnly, .broken, .inconclusive, .stale:
            return .verified(ms: nil, age: 0)
        }
    }
}

// MARK: - ProtocolsTally

/// One protocol (or room) of a server and what the evidence says about it.
struct ProtocolMark: Equatable, Sendable {
    let name: String
    let display: HealthDisplay
    /// Its container is not running on the server.
    var stopped = false
}

/// What a server's protocols add up to: how many work, how many there are, and
/// the NAMES of those that failed their last check. It feeds the card
/// headline and the whole-server row alike.
struct ProtocolsTally: Equatable, Sendable {
    var working = 0
    var total = 0
    /// Display names of the protocols whose last check failed, each once, in
    /// the order the card lists them.
    var failed: [String] = []
    /// The live tunnel runs through this server's whole-server connection,
    /// which covers rooms no protocol row lists.
    var carriedLive = false
    /// Display names of the stopped protocols, each once. They are in no
    /// other count.
    var stopped: [String] = []

    /// `rows` is how many rows the card draws: a container with no saved
    /// connection still draws one and has no mark, and a count that ignored it
    /// said "1 of 2" above three rows. A stopped row always has a mark, so
    /// the rows minus the stopped marks are the rows that count.
    static func make(_ marks: [ProtocolMark], rows: Int, carriedLive: Bool = false) -> ProtocolsTally {
        var tally = ProtocolsTally()
        tally.carriedLive = carriedLive
        let active = marks.filter { !$0.stopped }
        tally.total = max(active.count, rows - (marks.count - active.count))
        for mark in marks where mark.stopped && !tally.stopped.contains(mark.name) {
            tally.stopped.append(mark.name)
        }
        for mark in active {
            switch mark.display.standing {
            case .working:
                tally.working += 1
            case .failed:
                if !tally.failed.contains(mark.name) { tally.failed.append(mark.name) }
            case .unchecked, .stopped:
                break
            }
        }
        return tally
    }

    /// The server's standing: usable when anything works or the live tunnel is
    /// up through it; failed only when something was checked and nothing
    /// works; stopped when every protocol is; otherwise nobody can say yet. A
    /// tally that counted nothing defers to `fallback` (the summary verdict of
    /// callers that do not count).
    func standing(fallback: HealthDisplay) -> ProtocolStanding {
        if working > 0 || carriedLive { return .working }
        if !failed.isEmpty { return .failed }
        if total > 0 { return .unchecked }
        return stopped.isEmpty ? fallback.standing : .stopped
    }

    /// "Not responding: Telemost" — at most two names, then «+N». nil when
    /// nothing failed, so a healthy card carries no such line.
    var problemLine: String? { Self.problemLine(failed) }

    static func problemLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return L10n.protocolsNotResponding_fmt.formatted(namesList(names))
    }

    /// "Room stopped: MTS Link" — the rooms of a whole-server connection
    /// whose containers do not run. nil when none.
    var stoppedLine: String? {
        guard !stopped.isEmpty else { return nil }
        let format = stopped.count == 1 ? L10n.roomsStoppedOne_fmt : L10n.roomsStoppedMany_fmt
        return format.formatted(Self.namesList(stopped))
    }

    /// What a whole-server row says about its rooms: the ones that did not
    /// answer, then the stopped ones, a line each; nil when neither.
    var roomsNote: String? {
        let lines = [problemLine, stoppedLine].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// At most two names, then «+N».
    private static func namesList(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        let more = names.count - 2
        return more > 0 ? "\(shown) +\(more)" : shown
    }
}

// MARK: - StoppedProtocols

/// The records of a server whose protocol containers do not run, as the last
/// listing found them. A record a running row also resolves to is not
/// stopped (two rows of one carrier can fall back to the same record). The
/// whole-server record is stopped when its first room's container is: its own
/// check dials that room.
enum StoppedProtocols {
    @MainActor
    static func recordIDs(host: ServerHost, rows: [SSHRunner.CarrierInfo],
                          records: [ConnectionRecord]) -> Set<UUID> {
        var stopped = Set<UUID>()
        var running = Set<UUID>()
        for row in rows {
            guard let record = ServersView.resolveRecord(host: host, row: row, records: records) else { continue }
            if ServersView.isUp(row.status) {
                running.insert(record.id)
            } else {
                stopped.insert(record.id)
            }
        }
        stopped.subtract(running)
        if let id = host.bundleConnectionID,
           let bundle = records.first(where: { $0.id == id }),
           case .olcrtc(let params) = bundle.details {
            func holdsFirstRoom(_ row: SSHRunner.CarrierInfo) -> Bool {
                row.provider == params.carrier && RoomIdentity.same(params.roomID, row.room, carrier: params.carrier)
            }
            let first = rows.filter(holdsFirstRoom)
            if !first.isEmpty, !first.contains(where: { ServersView.isUp($0.status) }) {
                stopped.insert(id)
            }
        }
        return stopped
    }
}
