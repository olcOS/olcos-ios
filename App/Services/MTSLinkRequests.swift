import Foundation

// MARK: - CapturedRequest
//
// One HTTPS request the MTS Link page sent, remembered for the "what the app
// saw" list in the sign-in sheet (so the owner can hand the log over) and as
// the raw material of the lesson (MTSLinkLesson). Everything is SCRUBBED on the
// way in — a credential that was never stored cannot leak:
//
//   * the page replaces the value of every credential-named header with a
//     provenance marker (MTSLinkProvenance) before anything leaves it; a
//     credential value that still arrives is dropped here (the header name
//     stays, so the log still says what the page sent);
//   * the body goes through `MTSLinkScrub` and is capped at `maxBodyBytes`.
//
// Nothing captured ever goes to a network of its own: the buffer lives in the
// sheet, and only the template the owner confirmed is kept between launches
// (MTSLinkTemplateStore — UserDefaults, no secrets in it by construction).
struct CapturedRequest: Equatable, Codable, Sendable {
    var method: String
    var url: String
    /// Scrubbed: credential headers carry a provenance marker or `<redacted>`,
    /// never their value.
    var headers: [String: String]
    /// Scrubbed and capped at `maxBodyBytes`.
    var body: String

    /// The headers whose VALUE is a credential. Case-insensitive by name.
    static let credentialHeaders: Set<String> = ["cookie", "set-cookie",
                                                "authorization", "x-auth-token"]
    static let maxBodyBytes = 8 * 1024

    /// The scrubbed capture of one request. MainActor because the redactor is
    /// (LogStore).
    @MainActor
    static func scrubbed(method: String, url: String,
                         headers: [String: String], body: String) -> CapturedRequest {
        var kept: [String: String] = [:]
        for (name, value) in headers {
            if MTSLinkProvenance.parse(value) != nil {
                kept[name] = value
            } else if credentialHeaders.contains(name.lowercased()) || MTSLinkProvenance.isCredentialName(name) {
                kept[name] = "<redacted>"
            } else {
                kept[name] = MTSLinkScrub.text(value, limit: 512)
            }
        }
        return CapturedRequest(method: method.isEmpty ? "GET" : method.uppercased(),
                               url: url, headers: kept,
                               body: MTSLinkScrub.text(body, limit: maxBodyBytes))
    }

    /// The one-line form shown in the "what the app saw" list (no query: it
    /// may carry a token).
    var summary: String { "\(method) \(MTSLinkURL.withoutQuery(url))" }
}

// MARK: - MTSLinkURL

enum MTSLinkURL {
    /// PURE. The URL up to its query or fragment.
    static func withoutQuery(_ url: String) -> String {
        guard let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(url[..<cut])
    }

    /// PURE. Whether the URL is HTTPS on mts-link.ru or one of its subdomains
    /// — the only place a learned request may be replayed to. Read by hand, not
    /// through `URL`: a learned URL may carry `<<olc:…>>` markers in its path or
    /// query, which `URL` may refuse.
    static func isMTSLink(_ url: String) -> Bool {
        let prefix = "https://"
        guard url.lowercased().hasPrefix(prefix) else { return false }
        let rest = url.dropFirst(prefix.count)
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // No credentials in the authority, and no marker in the host.
        guard !authority.contains("@"), !authority.contains("<") else { return false }
        let host = authority.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return !host.isEmpty && MTSLinkSessionStore.isMTSDomain(host)
    }
}

// MARK: - MTSLinkScrub

/// Text that came out of the MTS Link page, made safe to keep or print. On top
/// of the app's log redactor (keys, bearer tokens, `access_token`, …) it masks
/// the JSON values of credential-looking keys and JWT-shaped strings, and cuts
/// at a byte limit. Idempotent.
enum MTSLinkScrub {
    private static let jsonSecretKey = try! NSRegularExpression(
        pattern: #"(?i)("[^"]*(?:token|secret|passw|authorization|cookie|session[_-]?id|api[_-]?key|csrf|xsrf)[^"]*"\s*:\s*)"(?:[^"\\]|\\.)*""#)
    private static let jwt = try! NSRegularExpression(
        pattern: #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#)

    @MainActor
    static func text(_ s: String, limit: Int) -> String {
        var out = LogStore.redactSecrets(s)
        let r1 = NSRange(out.startIndex..<out.endIndex, in: out)
        out = jsonSecretKey.stringByReplacingMatches(in: out, range: r1, withTemplate: "$1\"<redacted>\"")
        let r2 = NSRange(out.startIndex..<out.endIndex, in: out)
        out = jwt.stringByReplacingMatches(in: out, range: r2, withTemplate: "<redacted>")
        let bytes = Array(out.utf8)
        if bytes.count > limit {
            out = String(decoding: bytes[0..<limit], as: UTF8.self)
        }
        return out
    }
}

// MARK: - MTSLinkCreatedRooms

/// The meetings THIS app made (their event ids). Capped: the oldest id falls
/// off past `maxRooms`. UserDefaults, like RoomMemory — a meeting id is a
/// public conference identifier, not a secret. Nothing deletes a meeting
/// today (no delete request is known); the list says which rooms were the
/// app's own.
enum MTSLinkCreatedRooms {

    private static let storeKey = "olcrtc.mtslink.created-rooms.v1"
    static let maxRooms = 20

    /// PURE. The list with `id` remembered at the end, capped at `maxRooms`.
    static func appending(_ id: String, to ids: [String]) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ids }
        var out = ids.filter { $0 != trimmed }
        out.append(trimmed)
        return Array(out.suffix(maxRooms))
    }

    static func remember(_ id: String) {
        store = appending(id, to: store)
    }

    /// Whether this app made the meeting `id`.
    static func made(_ id: String) -> Bool {
        store.contains(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func forget(_ id: String) {
        store = store.filter { $0 != id.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static var store: [String] {
        get { UserDefaults.standard.stringArray(forKey: storeKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: storeKey) }
    }
}
