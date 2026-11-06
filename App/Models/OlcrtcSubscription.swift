import Foundation

// MARK: - OlcrtcSubscription (#111)
//
// Client-side subscription support. A subscription is a plain-text file
// hosted over HTTPS whose format is specified upstream in
// `olcrtc-upstream/docs/sub.md`:
//
//   #key: value      — global subscription fields (name, update, refresh, …)
//   olcrtc://…       — one server per line (docs/uri.md format)
//   ##key: value     — fields of the nearest *preceding* server line
//                      (name, color, icon, used, available, ip, comment)
//
// and two olcOS extensions other clients skip as unknown: `vless://` server
// lines (Xray · REALITY, docs/uri.md) and `##id`, a node identity that
// outlives the room and key behind it.
//
// The app reaches that file through an `olcrtc-sub://` link (registered as
// a URL scheme alongside `olcrtc`): the scheme is swapped to `https`, the
// rest of the URL (host, port, path, query) passes through unchanged.
// Upstream only specifies the *payload* format — the `olcrtc-sub://` link
// convention is defined by olcrtc-ios in docs/uri.md.
//
// Parsing is tolerant by design (the spec allows blank lines and clients
// must ignore fields they don't render): unknown `#`/`##` keys and stray
// text are skipped, and an `olcrtc://` line that fails to parse only bumps
// `skippedURIs` instead of failing the whole import. Of the metadata, only
// the names are consumed today — `#name` becomes the group of the imported
// records, `##name` the record name; the UI/quota fields (color, icon,
// used, available, ip, comment) and `#refresh` auto-update are not
// surfaced yet.

struct OlcrtcSubscription {

    /// One `olcrtc://` server line plus its `##` fields.
    struct Entry {
        let parsed: OlcrtcURI.Parsed
        var name: String?            // ##name
        // #363: previously-dropped per-node `##` metadata, now carried through
        // import onto the record so the group/node detail view can render it.
        // All server-provided free text — rendered defensively. Defaulted to nil
        // so the existing `Entry(parsed:name:)` call sites still compile.
        var used     : String? = nil // ##used (e.g. "500mb/10gb")
        var available: String? = nil // ##available
        var ip       : String? = nil // ##ip
        var comment  : String? = nil // ##comment
        /// ##id — a node identity the source keeps stable while the room or
        /// key behind it changes (a renewed Telemost room, a re-keyed server),
        /// so a refresh updates the saved connection instead of replacing it.
        var nodeID   : String? = nil
        /// ##lanes — more rooms of the same server, comma-separated (an olcOS
        /// extension): the connection joins them all and spreads its traffic.
        var lanes    : [String] = []
        /// ##with — the server's other protocols joined into this connection,
        /// `carrier?transport@room`, comma-separated (an olcOS extension):
        /// the whole-server connection (ServerBundle).
        var with     : [OlcrtcLane] = []
        /// ##bond — the server's bond endpoint, `host:port` (an olcOS
        /// extension): every connection then rides all lanes at once.
        var bond     : String? = nil

        /// Record name for the import — same fallback chain the manual URI
        /// import in AddConnectionView uses (mimo, then carrier·transport).
        var recordName: String {
            if let n = name, !n.isEmpty { return n }
            return parsed.mimo.isEmpty
                ? "\(parsed.carrier) · \(parsed.transport)"
                : parsed.mimo
        }

        /// Stable per-node identity for dedup across re-imports (#356). Keyed on
        /// the connection-defining fields only — carrier, transport, room, key,
        /// clientID — so re-editing a node's display name/comment upstream still
        /// maps to the same record. Display metadata (mimo/##name) is excluded.
        var nodeKey: String {
            if let nodeID, !nodeID.isEmpty { return "id\u{1}" + nodeID }
            // The room is one spelling (RoomIdentity): a node re-imported with
            // the phone-only ICE hint on its MTS Link link is the same node as
            // the same link without it. Every other room keys as it stands, so
            // a key saved before this rule still matches its record. The
            // `bundle` marker: a whole-server connection shares its first lane
            // with that protocol's own line; it stays one node while its lanes
            // change.
            return ([parsed.carrier, parsed.transport, RoomIdentity.key(parsed.carrier, parsed.roomID),
                     parsed.key, parsed.clientID] + (with.isEmpty ? [] : ["bundle"]))
                .joined(separator: "\u{1}")
        }

        /// `carrier?transport@room`, the form `##with` lists lanes in.
        static func lane(_ text: String) -> OlcrtcLane? {
            guard let q = text.firstIndex(of: "?") else { return nil }
            let rest = text[text.index(after: q)...]
            guard let at = rest.firstIndex(of: "@") else { return nil }
            let lane = OlcrtcLane(carrier: String(text[..<q]),
                                  transport: String(rest[..<at]),
                                  roomID: String(rest[rest.index(after: at)...]))
            return lane.carrier.isEmpty || lane.transport.isEmpty || lane.roomID.isEmpty ? nil : lane
        }

        static func text(_ lane: OlcrtcLane) -> String {
            "\(lane.carrier)?\(lane.transport)@\(lane.roomID)"
        }
    }

    /// One `vless://` (Xray · REALITY) line plus its `##` fields.
    struct XrayEntry {
        let parsed: XrayURI.Parsed
        var name: String?            // ##name
        var nodeID: String?          // ##id, as for `Entry`
        var ip: String? = nil        // ##ip
        var comment: String? = nil   // ##comment

        var recordName: String {
            if let n = name, !n.isEmpty { return n }
            return parsed.name.isEmpty ? parsed.params.fallbackName : parsed.name
        }

        /// The endpoint and the account, unless the source names the node.
        var nodeKey: String {
            if let nodeID, !nodeID.isEmpty { return "id\u{1}" + nodeID }
            let p = parsed.params
            return ["xray", p.host, String(p.port), p.uuid, p.sni].joined(separator: "\u{1}")
        }
    }

    var name: String?                // global #name
    var refresh: String?             // global #refresh (e.g. "5s", "10m", "6h", "1d") — #356
    // #363: previously-dropped global `#` metadata, now carried through onto the
    // per-source SubscriptionMeta so the group detail view can render quota.
    var used: String?                // global #used (e.g. "10mb/10gb")
    var available: String?           // global #available
    /// The `#agent*` fields of a device invite that hands over server access.
    var agentFields: [String: String] = [:]
    /// The server access the list carries, once every `#agent*` part is there.
    var agent: AgentOffer? { AgentOffer(fields: agentFields) }
    var entries: [Entry] = []
    var xrayEntries: [XrayEntry] = []
    var skippedURIs = 0              // olcrtc:// / vless:// lines that failed to parse

    /// Every connection the list carries, of either kind.
    var totalEntries: Int { entries.count + xrayEntries.count }
    var isEmpty: Bool { entries.isEmpty && xrayEntries.isEmpty }

    /// `#refresh` parsed to seconds (#356). Supports the `Ns`/`Nm`/`Nh`/`Nd`
    /// forms from sub.md's recommendations; a bare integer is read as seconds.
    /// nil = no/unparseable `#refresh` (the caller treats that as "never auto-refresh").
    var refreshInterval: TimeInterval? {
        guard let r = refresh?.trimmingCharacters(in: .whitespaces).lowercased(),
              !r.isEmpty else { return nil }
        let unit = r.last!
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default:
            // No unit suffix → treat the whole string as seconds.
            return TimeInterval(r).map { max(0, $0) }
        }
        guard let n = Double(r.dropLast()), n >= 0 else { return nil }
        return n * multiplier
    }

    enum SubError: LocalizedError {
        case invalidSubURL           // not olcrtc-sub:// or no host
        case emptySubscription       // fetched fine, but no usable server lines
        case allLinksSkipped(Int)    // every connection line failed to parse

        var errorDescription: String? {
            switch self {
            case .invalidSubURL:          return L10n.subInvalidLink.localized()
            case .emptySubscription:      return L10n.subEmptyList.localized()
            case .allLinksSkipped(let n): return L10n.subAllLinksSkipped_fmt.formatted(n)
            }
        }
    }

    // MARK: Paste-and-import detection (#361)

    /// What a pasted blob in the import box resolves to. The paste box accepts
    /// more than `olcrtc-sub://` deep links now: a single connection URI, a remote
    /// subscription URL to fetch, or raw sub.md text to parse directly.
    enum ImportInput: Equatable {
        case connectionURI(String)   // a single olcrtc:// link → single-connection import (#354)
        case subscriptionURL(URL)    // an https:// (or olcrtc-sub://) link → fetch then import
        case subscriptionBody(String) // raw sub.md text (multiple lines / markers) → parse then import
        case unrecognized
    }

    /// Classifies a pasted blob without any network or field side-effects (pure →
    /// tested). Order matters:
    ///   1. a lone `olcrtc://` line → single-connection URI;
    ///   2. an `olcrtc-sub://` or `https://` link → a subscription URL to fetch;
    ///   3. anything that looks like sub.md (an `olcrtc://` line among others, or a
    ///      `#`/`##` marker line) → raw subscription body to parse in place;
    ///   4. otherwise unrecognized.
    /// HTTPS-only for URLs (preserves the ATS / #008–#009 posture): a plain
    /// `http://` link is NOT treated as a subscription URL.
    static func detectImport(_ raw: String) -> ImportInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 1. A single olcrtc:// (or vless://, xray engine) connection link —
        //    one line, no sub.md markers. `AddConnectionView.parseURI` routes
        //    the two schemes to their codecs.
        if lines.count == 1, let only = lines.first,
           only.hasPrefix("olcrtc://") || XrayURI.matches(only) {
            return .connectionURI(only)
        }

        // 2. A single subscription link: olcrtc-sub:// (mapped to https) or https://.
        if lines.count == 1, let only = lines.first {
            let lower = only.lowercased()
            if lower.hasPrefix("olcrtc-sub://"), let url = URL(string: only) {
                return .subscriptionURL(url)
            }
            if lower.hasPrefix("https://"), let url = URL(string: only) {
                return .subscriptionURL(url)
            }
        }

        // 3. Raw sub.md body — multiple lines containing olcrtc:// lines and/or
        //    #/## marker lines — or a base64-encoded list.
        let looksLikeBody = lines.contains {
            $0.hasPrefix("olcrtc://") || XrayURI.matches($0) || $0.hasPrefix("#")
        }
        if looksLikeBody || decodedBase64Body(trimmed) != nil { return .subscriptionBody(trimmed) }

        // 4. A link with words around it ("here you go: olcrtc://…, enjoy") —
        //    the first one wins. Only a proper substring recurses: a bare link
        //    that reached this point would otherwise loop.
        if let link = firstLink(in: trimmed), link != trimmed { return detectImport(link) }

        return .unrecognized
    }

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:olcrtc-sub|olcrtc|vless|https)://\S+"#)

    /// The first connection, subscription or invite link inside free text,
    /// without the punctuation a sentence hangs on it.
    static func firstLink(in text: String) -> String? {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = linkRegex.firstMatch(in: text, range: whole),
              let r = Range(m.range, in: text) else { return nil }
        var link = String(text[r])
        while let last = link.last, ".,;:!?)]}>\"'»".contains(last) { link.removeLast() }
        return link.isEmpty ? nil : link
    }

    // MARK: olcrtc-sub:// → https:// mapping

    /// Maps an incoming `olcrtc-sub://host[:port]/path[?query]` link to the
    /// HTTPS URL the subscription file is fetched from. Only the scheme
    /// changes; HTTPS is not optional (no `http` opt-out — ATS would block
    /// it anyway and the URI carries the encryption keys).
    static func httpsURL(from url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "olcrtc-sub",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty else {
            throw SubError.invalidSubURL
        }
        comps.scheme = "https"
        guard let https = comps.url else { throw SubError.invalidSubURL }
        return https
    }

    // MARK: Payload parser (upstream sub.md)

    /// Parses a subscription body. Never throws — an unusable body simply
    /// yields zero entries (the caller decides that's `emptySubscription`).
    static func parse(_ body: String) -> OlcrtcSubscription {
        if let decoded = decodedBase64Body(body) { return parse(decoded) }
        var sub = OlcrtcSubscription()
        // Which list the latest connection line went to: `##` fields describe it.
        var lastIsXray = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Order matters: `##` (server field) before `#` (global field).
            if line.hasPrefix("##") {
                guard let (key, value) = field(of: line.dropFirst(2)) else { continue }
                if lastIsXray, !sub.xrayEntries.isEmpty {
                    let last = sub.xrayEntries.count - 1
                    switch key {
                    case "name":    sub.xrayEntries[last].name    = value
                    case "id":      sub.xrayEntries[last].nodeID  = value
                    case "ip":      sub.xrayEntries[last].ip      = value
                    case "comment": sub.xrayEntries[last].comment = value
                    default: break
                    }
                    continue
                }
                guard !sub.entries.isEmpty else { continue }
                let last = sub.entries.count - 1
                // #363: carry the useful per-node fields onto the entry; color/icon
                // remain accepted-but-unrendered (no Theme-token mapping for arbitrary
                // server-supplied hex/emoji).
                switch key {
                case "name":      sub.entries[last].name      = value
                case "used":      sub.entries[last].used      = value
                case "available": sub.entries[last].available = value
                case "ip":        sub.entries[last].ip        = value
                case "comment":   sub.entries[last].comment   = value
                case "id":        sub.entries[last].nodeID    = value
                case "lanes":
                    sub.entries[last].lanes = value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                case "with":
                    sub.entries[last].with = value.split(separator: ",")
                        .compactMap { Entry.lane($0.trimmingCharacters(in: .whitespaces)) }
                case "bond":
                    sub.entries[last].bond = ServerBundle.split(endpoint: value) == nil ? nil : value
                default: break
                }
            } else if line.hasPrefix("#") {
                guard let (key, value) = field(of: line.dropFirst(1)) else { continue }
                // #363: carry the useful global fields; update/color/icon remain
                // accepted-but-unrendered.
                switch key {
                case "name":      sub.name      = value
                case "refresh":   sub.refresh   = value   // #356: drives the "refresh due" check
                case "used":      sub.used      = value   // #363
                case "available": sub.available = value   // #363
                case "agent", "agent-cert", "agent-prefix", "agent-code", "agent-role":
                    sub.agentFields[key] = value
                // The header other clients' lists carry (v2rayN, Happ): the
                // title, and the refresh interval in hours.
                case "profile-title":
                    if sub.name == nil { sub.name = value }
                case "profile-update-interval":
                    if sub.refresh == nil, let hours = Int(value), hours > 0 { sub.refresh = "\(hours)h" }
                default: break
                }
            } else if line.hasPrefix("olcrtc://") {
                if let parsed = try? OlcrtcURI.parse(line) {
                    sub.entries.append(Entry(parsed: parsed, name: nil))
                    lastIsXray = false
                } else {
                    sub.skippedURIs += 1
                }
            } else if XrayURI.matches(line) {
                if let parsed = try? XrayURI.parse(line) {
                    sub.xrayEntries.append(XrayEntry(parsed: parsed, name: nil, nodeID: nil))
                    lastIsXray = true
                } else {
                    sub.skippedURIs += 1
                }
            }
            // anything else: stray text, ignored (tolerant per spec)
        }
        return sub
    }

    /// The text of a list served base64-encoded, as many providers do; nil
    /// unless the whole body is base64 and decodes to connection links.
    static func decodedBase64Body(_ body: String) -> String? {
        let compact = body.filter { !$0.isWhitespace }
        guard compact.count >= 16, !compact.contains("://"),
              compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) })
        else { return nil }
        var b64 = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8),
              text.contains("://") else { return nil }
        return text
    }

    /// Splits `key: value` (after the `#`/`##` prefix is stripped).
    private static func field(of s: Substring) -> (key: String, value: String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key   = s[s.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }
}
