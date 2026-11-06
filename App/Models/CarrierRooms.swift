import Foundation

// MARK: - Room references of the newer carriers
//
// The core takes a room reference verbatim and validates it itself; these
// helpers accept what people actually paste and turn it into the one shape the
// core expects, so a typo fails in the form rather than on the server.

/// A VK Calls join link. The core accepts exactly
/// `https://vk.ru/call/join/<id>` or `https://vk.com/call/join/<id>` — no
/// query, fragment or port (olcrtc-upstream internal/auth/vkcalls,
/// `canonicalLink`). The VK app copies the link inside a sentence, sometimes
/// with tracking parameters or the mobile host; all of that is dropped here.
enum VKCallLink {
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"(https?://)?(m\.)?vk\.(com|ru)/call/join/[A-Za-z0-9_\-]+"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        var link = String(text[range])
        if !link.lowercased().hasPrefix("http") { link = "https://" + link }
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return nil }
        let base = host.hasPrefix("m.") ? String(host.dropFirst(2)) : host
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, let id = parts.last else { return nil }
        return "https://\(base)/call/join/\(id)"
    }

    /// The join value `calls.start` returns may be the bare call id or a whole
    /// link (the API is not consistent about it); either becomes the one shape
    /// the core accepts: `https://vk.ru/call/join/<id>`. Anything else — empty,
    /// a foreign host, an id with characters VK does not use — is nil, never a
    /// guessed link.
    static func fromJoinValue(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = normalized(text) { return link }
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return "https://vk.ru/call/join/\(text)"
    }
}

/// An MTS Link room: the join link of a permanent meeting («постоянная
/// встреча»), `https://my.mts-link.ru/j/<owner>/<event>`, optionally with
/// `/session/<id>`, `/stream-new/<id>` or an ICE hint (`?ice=tcp`, also `udp` /
/// `both`) behind it. The core takes the event id out of the link and joins as
/// a guest (olcrtc-upstream internal/auth/mtslink, `parseEventLink`), so:
///
///   * the owner segment is not part of the room — the core reads the event
///     only, and wants BOTH segments to be digits, so a link carrying an alias
///     owner (`…/j/supportwebinar/…`) is rewritten to owner `0`. One spelling,
///     so the phone's record, the server config and every comparison agree;
///   * `/session/<id>` and `/stream-new/<id>` are dropped: they name one
///     occurrence (the page a meeting is shown on), the room is the meeting;
///   * other query parameters and fragments are dropped;
///   * a RECOGNIZED ICE hint survives as `?ice=<mode>` (olcrtc-upstream
///     internal/roomhint). It is part of the saved record and of the server's
///     config (`serverRoom`) and no part of the room's identity
///     (`RoomIdentity`): the hinted and the plain link are one room.
enum MTSLinkRoom {
    /// The hint's three modes, exactly as the core knows them.
    private static let iceModes = ["udp", "tcp", "both"]

    /// What a server is given when the person typed no hint: UDP first, TCP
    /// as the fallback. A server joins over UDP when its link carries nothing,
    /// and one UDP path to the SFU has been seen dying for hours while TCP kept
    /// working.
    static let defaultServerHint = "?ice=both"

    /// The one spelling of the room inside whatever was pasted (the VK app's
    /// habit of copying a link inside a sentence applies here too), hint kept,
    /// or nil when this is not an MTS Link meeting link.
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"(https?://)?(my\.)?mts-link\.ru/j/[A-Za-z0-9_\-]+/[A-Za-z0-9_\-]+"#,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let url = String(text[range])
        // The path is what names the room: /j/<owner>/<event>; whatever follows
        // it (/session/…, /stream-new/…) is outside the match and dropped.
        var parts = url.components(separatedBy: "/").filter { !$0.isEmpty }
        if parts.first?.hasSuffix(":") == true { parts.removeFirst() }   // the scheme
        guard parts.count == 4, parts[1] == "j",
              isID(parts[3])                       // the event: digits, like the core's isID
        else { return nil }
        // The owner is read by nobody (the core keeps the event alone), but its
        // shape is validated — so an alias owner becomes `0` rather than a
        // spelling the core's parser rejects.
        let owner = isID(parts[2]) ? parts[2] : "0"
        return "https://my.mts-link.ru/j/\(owner)/\(parts[3])" + iceHint(in: text, after: range)
    }

    /// The room without any hint. For identity and for display; a server is
    /// given `serverRoom`.
    static func plain(_ input: String) -> String? {
        normalized(input).map { room in
            guard let q = room.firstIndex(of: "?") else { return room }
            return String(room[..<q])
        }
    }

    /// The room as a SERVER config takes it: the plain link plus an ICE hint —
    /// the one the person typed, else `defaultServerHint`. Every install /
    /// add-protocol / reconfigure path sends this; the record on the phone
    /// keeps what was typed (`normalized`).
    static func serverRoom(_ input: String) -> String? {
        guard let room = normalized(input), let bare = plain(room) else { return nil }
        guard let q = room.firstIndex(of: "?") else { return bare + defaultServerHint }
        return bare + String(room[q...])
    }

    /// The phone's spelling of a room that came back from a server: the
    /// server's own default hint is no choice of the phone's person, so it is
    /// dropped (the phone keeps its default); a hint someone typed stays.
    static func phoneSpelling(ofServerRoom input: String) -> String? {
        guard let room = normalized(input) else { return nil }
        return room.hasSuffix(defaultServerHint) ? plain(room) : room
    }

    /// PURE. `?ice=<mode>` when the text right after the link ends in a hint
    /// the core recognizes (it looks at the LAST `?ice=` / `&ice=` and takes
    /// everything after it as the mode, so an unknown mode or a parameter
    /// behind it means no hint at all), else "".
    static func iceHint(in text: String, after link: Range<String.Index>) -> String {
        let tail = text[link.upperBound...]
        guard let question = tail.firstIndex(of: "?") else { return "" }
        let query = tail[tail.index(after: question)...]
            .prefix(while: { $0 != "#" && !$0.isWhitespace })
        var hint = ""
        for piece in query.split(whereSeparator: { $0 == "&" || $0 == "?" }) {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "ice" else { continue }
            let mode = String(kv[1])
            if iceModes.contains(mode) { hint = "?ice=\(mode)" }
        }
        return hint
    }

    /// The service's own ids: ASCII digits, not too many (the core's `isID`).
    static func isID(_ s: String) -> Bool {
        (1...20).contains(s.count) && s.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
    }

    /// The owner segment of a meeting link in the app's spelling (an alias
    /// owner is `0`). It is public — it sits in every link — and is the first
    /// number after `/j/`; the event is the second, and a `/stream-new/<session>`
    /// third number is neither.
    static func owner(of input: String) -> String? {
        guard let room = plain(input) else { return nil }
        let parts = room.split(separator: "/").map(String.init)
        // ["https:", "my.mts-link.ru", "j", owner, event]
        guard parts.count == 5 else { return nil }
        return parts[3]
    }

    /// The event id of a meeting link — the part that NAMES the room: the core
    /// reads it out of the link and joins by it, discarding the owner segment
    /// entirely (olcrtc-upstream internal/auth/mtslink, `parseEventLink`).
    /// nil when this is not an MTS Link meeting link.
    static func event(of input: String) -> String? {
        guard let room = plain(input) else { return nil }
        return room.split(separator: "/").last.map(String.init)
    }

    /// Every meeting link inside `text`, each in its one spelling, in the order
    /// they appear. What reads a create-meeting response and the page's own
    /// links (MTSLinkLearner) — a response may quote the meeting it was made
    /// from as well as the one it made, and a JSON body spells `/` as `\/`.
    static func links(in raw: String) -> [String] {
        let text = raw.replacingOccurrences(of: "\\/", with: "/")
        guard let regex = try? NSRegularExpression(
            pattern: #"(https?://)?(my\.)?mts-link\.ru/j/[A-Za-z0-9_\-]+/[A-Za-z0-9_\-]+"#,
            options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let room = normalized(ns.substring(with: match.range)), !out.contains(room) {
                out.append(room)
            }
        }
        return out
    }
}

/// How the app decides two room references name the SAME room — one rule for
/// every comparison (a row to its record, a rotated room to its age, a probe
/// to the live session). An MTS Link room is its MEETING — the event id the
/// core reads out of the link and joins by — so neither the ICE hint nor the
/// owner segment is part of it: the phone joins with `?ice=tcp`, the server
/// with `?ice=both`, and `…/j/supportwebinar/…` and `…/j/100200300/…` are one
/// room (MTSLinkRoom). Every other room is compared as it stands — case
/// included, because a room id is not always case-free.
enum RoomIdentity {
    /// The comparison key: the room as one spelling. Not for display.
    static func key(_ carrier: String, _ room: String) -> String {
        let trimmed = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard carrier == "mtslink" else { return trimmed }
        // A text the shape rules cannot parse names nothing the app
        // understands, so it is equal only to itself.
        return MTSLinkRoom.event(of: trimmed) ?? trimmed
    }

    static func same(_ a: String, _ b: String, carrier: String) -> Bool {
        key(carrier, a) == key(carrier, b)
    }

    /// The spelling a record keeps for the room a server just confirmed: what
    /// the phone typed (an MTS Link link typed without a hint stays without
    /// one although the server was given `?ice=both`), unless it names a
    /// different room than the one the server reported — then the server is
    /// right.
    static func phoneRoom(carrier: String, confirmed: String, typed: String) -> String {
        same(typed, confirmed, carrier: carrier) ? typed : fromServer(carrier: carrier, room: confirmed)
    }

    /// A room as a server reports it, in the phone's spelling: for MTS Link the
    /// server's own default hint is dropped.
    static func fromServer(carrier: String, room: String) -> String {
        guard carrier == "mtslink" else { return room }
        return MTSLinkRoom.phoneSpelling(ofServerRoom: room) ?? room
    }
}

/// What a room field accepts, per carrier, in one place for every form that
/// asks for a room (the wizard, Add protocol, Reconfigure, the connection
/// editor): the normalised value the server and the saved connection get,
/// whether it is usable, and the hint under the field.
enum CarrierRoomInput {
    /// "" when the input is not a usable room for this carrier.
    static func normalized(carrier: String, _ raw: String) -> String {
        switch carrier {
        case "telemost":   return TelemostRoomService.normalizedRoomInput(raw)
        case "vkcalls":    return VKCallLink.normalized(raw) ?? ""
        case "salutejazz": return SaluteJazzRoom.normalized(raw) ?? ""
        case "mtslink":    return MTSLinkRoom.normalized(raw) ?? ""
        default:           return raw.components(separatedBy: .whitespacesAndNewlines).joined()
        }
    }

    /// Jitsi accepts an empty room (the server generates one); the others
    /// need one in their own shape.
    static func isValid(carrier: String, _ raw: String) -> Bool {
        carrier == "jitsi" || !normalized(carrier: carrier, raw).isEmpty
    }

    static func hint(carrier: String) -> String {
        switch carrier {
        case "telemost":   return L10n.roomIDTelemostHint.localized() + " " + L10n.roomIDLinkHint.localized()
        case "vkcalls":    return L10n.roomIDVkHint.localized()
        case "salutejazz": return L10n.roomIDSaluteHint.localized()
        case "mtslink":    return L10n.roomIDMtslinkHint.localized()
        default:           return L10n.addFlowJitsiRoomHint.localized()
        }
    }

    static func placeholder(carrier: String) -> String {
        switch carrier {
        case "vkcalls":    return "https://vk.com/call/join/…"
        case "salutejazz": return "abcd12:efgh3456"
        case "mtslink":    return "https://my.mts-link.ru/j/…"
        case "jitsi":      return "olc-room"
        default:           return L10n.roomIDPlaceholder.localized()
        }
    }
}

/// A SaluteJazz room reference: `<code>:<password>`, each half 4–16 lowercase
/// letters or digits (olcrtc-upstream internal/auth/salutejazz, `splitRoomRef`).
/// The password half is a credential: it is masked in logs (LogStore).
enum SaluteJazzRoom {
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let halves = text.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2, halves.allSatisfy(isPart) else { return nil }
        return text
    }

    static func isPart(_ s: Substring) -> Bool {
        (4...16).contains(s.count) && s.allSatisfy { ($0.isASCII && $0.isLetter && $0.isLowercase) || $0.isASCII && $0.isNumber }
    }
}
