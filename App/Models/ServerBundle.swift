import Foundation

// MARK: - ServerBundle
//
// The whole-server connection. A server runs several olcrtc protocols
// (sibling containers) and several rooms per protocol (lanes); picking one of
// them by hand stops making sense once the app can use them all at once. The
// whole-server connection is one record that joins every protocol and room of
// the server: the engine starts a runtime per lane and, when the server runs
// the bond endpoint (gomobile/bond, SSHRunner+Bond), carries every connection
// an app opens over all of them together — one download gets the sum of the
// rooms' speeds and survives a room dropping out. Without the endpoint the
// lanes take turns per connection (LaneBalancer).
//
// The record is derived, never edited: BundleSync rebuilds it from the
// server's protocol records whenever one of them changes (a renewed room, a
// rotated key, a protocol or room added or removed). Pure → unit-tested.

enum ServerBundle {

    /// The whole-server connection for a server's protocol connections, the
    /// primary first; nil for a single protocol (its own record already joins
    /// its rooms) or when a key is missing (the Keychain was still locked).
    static func params(protocols: [OlcrtcConnection], bond: String?) -> OlcrtcConnection? {
        let plain = protocols.filter { !$0.isBundle }
        guard plain.count >= 2, var bundle = plain.first,
              plain.allSatisfy({ !$0.key.isEmpty }) else { return nil }
        var joined: [OlcrtcLane] = []
        var seen = Set(bundle.lanes)
        for other in plain.dropFirst() {
            for lane in other.lanes where seen.insert(lane).inserted {
                joined.append(lane)
            }
            // One token per WB account; a wbstream lane takes it from wherever
            // it was set.
            if bundle.wbToken.isEmpty, other.carrier == "wbstream" {
                bundle.wbToken = other.wbToken
            }
            if bundle.vp8FPS == nil, other.transport == "vp8channel", other.vp8FPS != nil {
                bundle.vp8FPS = other.vp8FPS
                bundle.vp8BatchSize = other.vp8BatchSize
            }
        }
        guard !joined.isEmpty else { return nil }
        bundle.bundleLanes = joined
        bundle.bond = bond
        bundle.roomCreatedAt = nil
        return bundle
    }

    /// The bond endpoint a protocol record rides: its own extra rooms are
    /// bonded too when the server has an endpoint; one room needs none.
    static func bond(for params: OlcrtcConnection, endpoint: String?) -> String? {
        params.lanes.count > 1 ? endpoint : nil
    }

    /// "host:port" of a server's bond endpoint, when it runs one.
    static func endpoint(host: ServerHost) -> String? {
        guard let port = host.bondPort, (1...65_535).contains(port) else { return nil }
        let name = host.host.contains(":") ? "[\(host.host)]" : host.host
        return "\(name):\(port)"
    }

    /// Splits "host:port" (IPv6 in brackets); nil when malformed.
    static func split(endpoint: String) -> (host: String, port: Int)? {
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...]),
              (1...65_535).contains(port) else { return nil }
        var host = String(endpoint[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    /// Does this connection ride the given room of the given carrier? True
    /// for the protocol's own record and for a whole-server connection that
    /// joined it — the Telemost renewal must not pull a room from under
    /// either.
    static func rides(_ params: OlcrtcConnection, carrier: String, roomID: String) -> Bool {
        // The room is compared by its ONE spelling (RoomIdentity): a lane and
        // a record can name an MTS Link room with and without its ICE hint.
        params.lanes.contains {
            $0.carrier == carrier && RoomIdentity.same($0.roomID, roomID, carrier: carrier)
        }
    }

    /// The protocol records a whole-server connection already covers: same
    /// key, and their primary room is one of its lanes. The main screen folds
    /// them away under the whole-server row — choosing a protocol by hand is
    /// what the bundle replaces.
    static func coveredIDs(in records: [ConnectionRecord]) -> Set<UUID> {
        var lanesByKey: [String: Set<OlcrtcLane>] = [:]
        for record in records {
            guard case .olcrtc(let p) = record.details, p.isBundle, !p.key.isEmpty else { continue }
            lanesByKey[p.key, default: []].formUnion(p.lanes)
        }
        guard !lanesByKey.isEmpty else { return [] }
        var covered = Set<UUID>()
        for record in records {
            guard case .olcrtc(let p) = record.details, !p.isBundle,
                  let lanes = lanesByKey[p.key] else { continue }
            if lanes.contains(OlcrtcLane(carrier: p.carrier, transport: p.transport, roomID: p.roomID)) {
                covered.insert(record.id)
            }
        }
        return covered
    }

    /// The protocol records one whole-server connection joins: same key, and
    /// their primary room is one of its lanes. Their verdicts are what the
    /// whole-server row stands on — its own check reaches the first room only.
    static func rooms(of bundle: ConnectionRecord, in records: [ConnectionRecord]) -> [ConnectionRecord] {
        guard case .olcrtc(let b) = bundle.details, b.isBundle, !b.key.isEmpty else { return [] }
        let lanes = Set(b.lanes)
        return records.filter { record in
            guard record.id != bundle.id, case .olcrtc(let p) = record.details,
                  !p.isBundle, p.key == b.key else { return false }
            return lanes.contains(OlcrtcLane(carrier: p.carrier, transport: p.transport, roomID: p.roomID))
        }
    }

    /// The services a whole-server connection joins, in order, each once —
    /// "Yandex Telemost + VK Calls + SaluteJazz".
    static func servicesLine(_ params: OlcrtcConnection) -> String {
        var carriers: [String] = []
        for lane in params.lanes where !carriers.contains(lane.carrier) {
            carriers.append(lane.carrier)
        }
        return carriers.map(CarrierTransportMatrix.carrierLabel).joined(separator: " + ")
    }
}
