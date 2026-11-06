import CryptoKit
import Foundation

// MARK: - Device invites
//
// "Invite a device": the phone that holds a server's SSH access publishes an
// encrypted subscription for another device on that VPS and keeps it current.
// When one of the server's connections changes — a renewed Telemost room, a
// rotated key, a protocol added or removed — the list is encrypted again and
// re-uploaded (InviteSync), and the other device takes the change on its next
// refresh instead of needing a new link.
//
//   olcrtc-sub://<vps>:<port>/<token>?enc=v1#<key>
//
// The VPS serves the file `<token>` over plain HTTP from a small busybox
// container (SSHRunner+Share). What it serves is AES-GCM ciphertext; the key
// exists only in the link's fragment, which is never part of a request, so
// neither the VPS nor anyone watching the exchange can read the list. The
// device fetches it with Network.framework (InviteFetcher): App Transport
// Security cannot be scoped to a bare IP, and the list is authenticated by
// its key rather than by TLS.
//
// The invited device gets connections, not SSH access. Revoking an invite
// deletes its file, which stops the updates; connections the device already
// has keep working until the server key is rotated — and the invites that
// remain receive the new key by themselves.

struct DeviceInvite: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// Who the link was made for ("iPad"); shown in the list only.
    var name: String
    /// File name of the encrypted list on the server: 32 lowercase hex digits.
    let token: String
    let createdAt: Date
    /// When the current list was uploaded; nil until the first upload.
    var publishedAt: Date?
    /// SHA-256 of the plaintext list last uploaded. A change to the server's
    /// connections changes the list, and with it this digest.
    var publishedDigest: String?
    /// The one-time code the server agent minted for this device (CLI
    /// `olcos-agent invite`), carried in its list so the device registers its
    /// own key with the agent; nil when the invite gives connections only.
    var agentCode: String? = nil
    /// The role that code grants: "member" (rooms: see, restart) or "owner"
    /// (every maintenance action).
    var agentRole: String? = nil

    init(name: String, token: String = InviteLink.makeToken(), createdAt: Date = Date()) {
        id = UUID()
        self.name = name
        self.token = token
        self.createdAt = createdAt
    }

    /// The invite's public name on the server: the first 8 lowercase hex
    /// digits of SHA-256 of its token. The token stays secret (it names the
    /// list's file); its hash tells nothing about it. The list's links carry
    /// it as `inv-<tag>`, and the Devices screen matches the server's device
    /// ids on it. The Android app derives the same tag.
    var tag: String { Self.tag(forToken: token) }

    /// The clientID this invite's list puts on every olcrtc link.
    var clientID: String { DeviceIdentity.inviteClientID(tag: tag) }

    static func tag(forToken token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

enum InviteError: LocalizedError, Equatable {
    case invalidLink
    case missingKey
    case notAnInvite
    case wrongKey
    case revoked

    var errorDescription: String? {
        switch self {
        case .invalidLink: return L10n.inviteErrorInvalidLink.localized()
        case .missingKey:  return L10n.inviteErrorMissingKey.localized()
        case .notAnInvite: return L10n.inviteErrorNotAnInvite.localized()
        case .wrongKey:    return L10n.inviteErrorWrongKey.localized()
        case .revoked:     return L10n.inviteErrorRevoked.localized()
        }
    }
}

// MARK: - Link

enum InviteLink {
    static let scheme = "olcrtc-sub"
    static let version = "v1"

    struct Parsed: Equatable {
        let host: String
        let port: Int
        let token: String
        let key: Data

        /// The link without its key: what may be stored and logged.
        var source: String { InviteLink.source(host: host, port: port, token: token) }
    }

    static func makeToken() -> String {
        randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    static func makeKey() -> Data { Data(randomBytes(32)) }

    static func isWellFormedToken(_ token: String) -> Bool {
        token.count == 32 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func encode(host: String, port: Int, token: String, key: Data) -> String {
        source(host: host, port: port, token: token) + "#" + base64URL(key)
    }

    static func source(host: String, port: Int, token: String) -> String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(shown):\(port)/\(token)?enc=\(version)"
    }

    /// Whether a subscription link, with or without its key, is an invite.
    static func isInvite(_ link: String) -> Bool {
        guard let comps = URLComponents(string: link) else { return false }
        return comps.scheme?.lowercased() == scheme
            && comps.queryItems?.first(where: { $0.name == "enc" })?.value == version
    }

    /// A full link, key included.
    static func parse(_ link: String) throws -> Parsed {
        guard let comps = URLComponents(string: link),
              let (host, port, token) = endpoint(components: comps) else { throw InviteError.invalidLink }
        guard let fragment = comps.fragment, let key = data(base64URL: fragment), key.count == 32 else {
            throw InviteError.missingKey
        }
        return Parsed(host: host, port: port, token: token, key: key)
    }

    /// Host, port and token of an invite link; its key is not needed.
    static func endpoint(of link: String) -> (host: String, port: Int, token: String)? {
        URLComponents(string: link).flatMap(endpoint(components:))
    }

    private static func endpoint(components comps: URLComponents) -> (host: String, port: Int, token: String)? {
        guard comps.scheme?.lowercased() == scheme,
              comps.queryItems?.first(where: { $0.name == "enc" })?.value == version,
              var host = comps.host, let port = comps.port, (1...65535).contains(port)
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let token = String(comps.path.drop(while: { $0 == "/" }))
        guard !host.isEmpty, isWellFormedToken(token) else { return nil }
        return (host, port, token)
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}

// MARK: - Encryption

enum InviteCipher {
    /// Marks the served text as an invite list, and its format version.
    static let prefix = "olcos1:"
    private static let associatedData = Data("olcos-invite-v1".utf8)

    static func seal(_ plaintext: String, key: Data) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: key),
                                   authenticating: associatedData)
        guard let combined = box.combined else { throw InviteError.notAnInvite }
        return prefix + combined.base64EncodedString()
    }

    static func open(_ served: String, key: Data) throws -> String {
        let text = served.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix),
              let combined = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw InviteError.notAnInvite
        }
        guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key),
                                            authenticating: associatedData),
              let body = String(data: plain, encoding: .utf8) else {
            throw InviteError.wrongKey
        }
        return body
    }
}

// MARK: - The list

/// What an invited device needs to register with the server agent: where the
/// agent is, the certificate it pins, the API prefix and its one-time code.
/// Travels inside the encrypted list as `#agent*` global fields.
struct AgentOffer: Equatable {
    var host: String
    var port: Int
    var certSHA256: String
    var prefix: String
    var code: String
    var role: String

    /// The global lines of the list, in a fixed order.
    var lines: [String] {
        let shown = host.contains(":") ? "[\(host)]" : host
        return [
            "#agent: \(shown):\(port)",
            "#agent-cert: \(certSHA256)",
            "#agent-prefix: \(prefix)",
            "#agent-code: \(code)",
            "#agent-role: \(role)",
        ]
    }
}

extension AgentOffer {
    /// The offer read back from a list's global fields (`agent` to `agent-role`,
    /// keys without the `#`); nil unless every part is there and well-formed.
    init?(fields: [String: String]) {
        guard let address = fields["agent"], let cert = fields["agent-cert"],
              let prefix = fields["agent-prefix"], let code = fields["agent-code"],
              let colon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, cert.count == 64, !prefix.isEmpty, !code.isEmpty else { return nil }
        self.init(host: host, port: port, certSHA256: cert.lowercased(), prefix: prefix, code: code,
                  role: fields["agent-role"] == "owner" ? "owner" : "member")
    }
}

enum InvitePayload {
    /// How often an invited device looks for changes (subscription `#refresh`).
    static let refresh = "30m"

    /// The list an invited device receives: every connection of the server,
    /// each under its record id as `##id`, which outlives a room or key change,
    /// and, when the invite gives server access, the agent offer. nil when a
    /// secret is missing (the Keychain was still locked): a list without keys
    /// would replace working connections with broken ones.
    /// `inviteTag` (DeviceInvite.tag) puts `inv-<tag>` on every olcrtc link,
    /// so the server's log says which invite a device came in on; without it
    /// the links keep the `default` placeholder.
    static func body(serverName: String, records: [ConnectionRecord], agent: AgentOffer? = nil,
                     inviteTag: String? = nil) -> String? {
        guard !records.isEmpty else { return nil }
        var lines = ["#name: \(oneLine(serverName))", "#refresh: \(refresh)"]
        if let agent { lines += agent.lines.map(oneLine) }
        // The admin's own clientID never travels: each device announces its own
        // name in the room, after the invite's id when there is one (DeviceIdentity).
        let clientID = inviteTag.map { DeviceIdentity.inviteClientID(tag: $0) } ?? DeviceIdentity.placeholder
        for record in records {
            switch record.details {
            case .olcrtc(var params):
                guard !params.key.isEmpty else { return nil }
                params.clientID = clientID
                lines.append(OlcrtcURI.encode(params))
                lines.append("##name: \(oneLine(record.name))")
                // When the room was made: a Telemost room lives 24 h, and the
                // invited device renews what it owns before that (Android).
                if let created = params.roomCreatedAt {
                    lines.append("##created: \(Int(created.timeIntervalSince1970))")
                }
                if let lanes = params.extraRooms, !lanes.isEmpty {
                    lines.append("##lanes: \(lanes.map(oneLine).joined(separator: ","))")
                }
                if let joined = params.bundleLanes, !joined.isEmpty {
                    let listed = joined.map { oneLine(OlcrtcSubscription.Entry.text($0)) }
                    lines.append("##with: \(listed.joined(separator: ","))")
                }
                if let bond = params.bond, params.lanes.count > 1 {
                    lines.append("##bond: \(oneLine(bond))")
                }
            case .xray(let params):
                guard !params.uuid.isEmpty else { return nil }
                lines.append(XrayURI.encode(params))
                lines.append("##name: \(oneLine(record.name))")
            }
            lines.append("##id: \(record.id.uuidString.lowercased())")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func digest(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A name can't start a new line of the list.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
