import Foundation

// MARK: - XrayConnection (protocol-specific params)
//
// VLESS + REALITY (xtls-rprx-vision) endpoint as consumed by the olcos-core
// Xray engine (olcos-core/engine/xray). Pure protocol parameters — no name, no
// group, no id; those live on the wrapping ConnectionRecord, exactly like
// `OlcrtcConnection`. Mirrors olcos-core/profile (Profile.Params keys).
//
// Canonical link (docs/HANDOFF.md §4 of olcos-core):
//   vless://<uuid>@<host>:<port>?encryption=none&flow=xtls-rprx-vision
//         &security=reality&sni=<sni>&fp=chrome&pbk=<pbk>&sid=<sid>&spx=%2F
//         &type=tcp#<name>
//
// `uuid` is the client credential — the exact analogue of `OlcrtcConnection.key`.
// It is Keychain-only: `ConnectionStore.save()` blanks it before the record hits
// UserDefaults and `hydrateSecrets` restores it (reusing the `key` Keychain slot,
// so `ConnectionSecretStore.remove` needs no new service).

struct XrayConnection: Codable, Equatable, Sendable {
    var host:        String
    var port:        Int
    var uuid:        String          // Keychain-only (see above)
    var sni:         String          // REALITY serverName (the camouflage site)
    var publicKey:   String          // pbk — REALITY x25519 public key, base64url
    var shortID:     String          // sid — hex, may be empty
    var fingerprint: String = "chrome"
    var flow:        String = "xtls-rprx-vision"
    var spiderX:     String = "/"

    static let defaultPort = 443

    /// "host:port" — the secondary line when the user set no name.
    var fallbackName: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }

    init(host: String, port: Int = XrayConnection.defaultPort, uuid: String,
         sni: String, publicKey: String, shortID: String = "",
         fingerprint: String = "chrome", flow: String = "xtls-rprx-vision",
         spiderX: String = "/") {
        self.host        = host
        self.port        = port
        self.uuid        = uuid
        self.sni         = sni
        self.publicKey   = publicKey
        self.shortID     = shortID
        self.fingerprint = fingerprint
        self.flow        = flow
        self.spiderX     = spiderX
    }
}

// MARK: - XrayURI
//
// The `vless://` codec. Kept dependency-free (Foundation only) so the model
// stays unit-testable and the same parser can be reused by the import paths
// (`AddConnectionView`, `App.swift` deep links). olcos-core has the authoritative
// Go parser (profile.Parse); this one accepts the same canonical form and the
// common variants clients emit (missing `encryption`, `type`, `spx`, `sid`).

enum XrayURI {

    struct Parsed: Equatable {
        var params: XrayConnection
        /// The `#fragment`, percent-decoded. Empty when the link carries none.
        var name: String
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidScheme
        case missingField(String)
        case unsupported(String)   // security != reality, or a non-tcp transport

        var errorDescription: String? {
            switch self {
            case .invalidScheme:       return L10n.uriErrorInvalidScheme.localized()
            case .missingField(let f): return L10n.uriErrorMissingField_fmt.formatted(f)
            case .unsupported(let w):  return L10n.xrayUriUnsupported_fmt.formatted(w)
            }
        }
    }

    static let scheme = "vless"

    /// True when `raw` looks like a link this codec should handle — the import
    /// paths use it to route between `OlcrtcURI` and `XrayURI` before parsing.
    static func matches(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("\(scheme)://")
    }

    static func encode(_ p: XrayConnection, name: String = "") -> String {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.user   = p.uuid
        comps.host   = p.host
        comps.port   = p.port
        var items: [URLQueryItem] = [
            URLQueryItem(name: "encryption", value: "none"),
            URLQueryItem(name: "flow",       value: p.flow),
            URLQueryItem(name: "security",   value: "reality"),
            URLQueryItem(name: "sni",        value: p.sni),
            URLQueryItem(name: "fp",         value: p.fingerprint),
            URLQueryItem(name: "pbk",        value: p.publicKey),
        ]
        if !p.shortID.isEmpty { items.append(URLQueryItem(name: "sid", value: p.shortID)) }
        items.append(URLQueryItem(name: "spx",  value: p.spiderX))
        items.append(URLQueryItem(name: "type", value: "tcp"))
        comps.queryItems = items
        // URLComponents leaves "/" unescaped in query values; the canonical link
        // (and xray-core's own share links) carry spx as %2F.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "spx=/", with: "spx=%2F")
        var out = comps.string ?? ""
        if !name.isEmpty {
            let allowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#%&+"))
            out += "#" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
        }
        return out
    }

    static func parse(_ raw: String) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(trimmed) else { throw Error.invalidScheme }
        // Split the fragment off by hand: a name containing "?" or "@" must not
        // confuse URLComponents, and we want the fragment percent-decoded once.
        var body = trimmed
        var name = ""
        if let hash = trimmed.firstIndex(of: "#") {
            body = String(trimmed[..<hash])
            name = String(trimmed[trimmed.index(after: hash)...]).removingPercentEncoding
                ?? String(trimmed[trimmed.index(after: hash)...])
        }
        guard let comps = URLComponents(string: body) else { throw Error.invalidScheme }
        guard let uuid = comps.user, !uuid.isEmpty else { throw Error.missingField("uuid") }
        guard let host = comps.host, !host.isEmpty else { throw Error.missingField("host") }
        let port = comps.port ?? XrayConnection.defaultPort

        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }

        let security = (q["security"] ?? "").lowercased()
        guard security == "reality" else { throw Error.unsupported("security=\(security.isEmpty ? "none" : security)") }
        // "raw" is Xray's newer name for the same TCP transport.
        let type = (q["type"] ?? "tcp").lowercased()
        guard type == "tcp" || type == "raw" else { throw Error.unsupported("type=\(type)") }
        let encryption = (q["encryption"] ?? "none").lowercased()
        guard encryption == "none" else { throw Error.unsupported("encryption=\(encryption)") }
        guard let pbk = q["pbk"], !pbk.isEmpty else { throw Error.missingField("pbk") }
        guard let sni = q["sni"] ?? q["servername"], !sni.isEmpty else { throw Error.missingField("sni") }

        let params = XrayConnection(
            host: host, port: port, uuid: uuid, sni: sni, publicKey: pbk,
            shortID: q["sid"] ?? "",
            fingerprint: q["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome",
            flow: q["flow"] ?? "",
            spiderX: q["spx"].flatMap { $0.isEmpty ? nil : $0 } ?? "/")
        return Parsed(params: params, name: name)
    }
}
