import Foundation
import WebKit

// MARK: - VKSessionStore
//
// Keychain home of the ONE credential that lets the phone create a VK call
// itself: the vk.ru cookie jar of a signed-in VK account, whose `remixsid`
// session cookie is the part that carries the identity.
//
// Why this file exists
// --------------------
// VK has no anonymous way to start a call, so the app mints calls with the
// user's OWN account (VKCallRoomService). Nobody automates the VK password, so
// the proven pattern from YandexSessionStore applies: the human signs in ONCE
// in a real web view, the app lifts the cookies that sign-in produced and
// reuses them.
//
// Why the whole jar and not `remixsid` alone
// ------------------------------------------
// The reference implementation (kulikov0/whitelist-bypass) sends VK's login
// service every vk.ru cookie the browser holds, as a browser would. A lone
// `remixsid` was not accepted for an account the web view showed as signed in,
// so the credential is the jar: one `Cookie`-header string,
// `remixsid=…; remixstid=…; remixua=…`, with `remixsid` first. A bare
// `remixsid` value — what earlier builds stored — is still read and still sent
// as `remixsid=<value>`.
//
// Why the handling is paranoid
// ----------------------------
// A live `remixsid` is a bearer credential for the user's ENTIRE VK identity —
// messages, profile, VK Pay — usable without the password. So, exactly like the
// Yandex session and the connection key:
//
//   * Keychain ONLY. Never UserDefaults, never a file, never a backup.
//   * Never logged — not the jar, not a cookie value, not a prefix, not a
//     length. The only facts about the credential that may reach a log are
//     WHETHER a session exists and how many cookies a jar carries
//     (`cookieCount`).
//   * Never put in an error message or an exported diagnostic. `hasSession` is
//     the only fact that leaves this type without the caller asking for the
//     value outright.
//   * The jar is rebuilt from validated pairs every time it is stored, read or
//     put into a request: a name that is not an RFC 6265 token, or a value
//     that could not travel in a `Cookie` header, is dropped, and a stray CR/LF
//     can never become header injection.
//
// Shape
// -----
// The same as YandexSessionStore: an `ObservableObject` so a view can bind to
// `hasSession`, plus `nonisolated static` readers so nonisolated service code
// (VKCallRoomService) can fetch the credential without hopping to MainActor.
// No shared singleton — the store owns no state beyond the published flag.
//
// Unlike YandexLoginView, the web-view jar keeps the cookies after capture:
// `resolvedSession()` re-reads them as a fallback, and "sign out" is the moment
// the web copy is purged together with the Keychain item, so the forget is
// still complete.

@MainActor
final class VKSessionStore: ObservableObject {

    // MARK: Naming

    /// The cookie that IS the identity — what the VK web client itself keeps a
    /// session in. A jar without it is not a session.
    nonisolated static let cookieName = "remixsid"

    /// Registrable domain the cookies are scoped to. Used to pick the right
    /// cookies out of a web view's jar — matching on the name alone would
    /// accept a same-named cookie from an unrelated host.
    nonisolated static let cookieDomain = "vk.ru"

    /// VK's cookie-deletion idiom, confirmed by live probes: the value
    /// survives every syntactic check and is worth nothing.
    nonisolated private static let deletedValue = "DELETED"

    // House convention: `olcrtc.yandex.session`, `olcrtc.serverhost.password`.
    nonisolated private static let keychainService = "olcrtc.vk.session"
    nonisolated private static let keychainAccount = "remixsid"

    // MARK: Observable state

    /// Whether an account is linked. The ONLY thing about the credential that is
    /// ever published, logged or shown.
    @Published private(set) var hasSession: Bool = false

    init() {
        hasSession = Self.hasStoredSession()
    }

    // MARK: Read / write

    /// Stores the credential — the cookie jar the sign-in sheet hands over, or a
    /// bare `remixsid` value — replacing any previous one.
    ///
    /// A value that does not survive `normalizeStored` is REJECTED without
    /// touching what is already stored — a bad paste must never silently unlink
    /// a working account. Returns whether the Keychain write happened.
    @discardableResult
    func save(_ session: String) -> Bool {
        guard let value = Self.normalizeStored(session) else {
            LogStore.shared.log(.provisioning,
                "⚠ VK sign-in ignored: the value is not a usable session cookie")
            return false
        }
        let ok = KeychainHelper.set(value,
                                    service: Self.keychainService,
                                    account: Self.keychainAccount)
        if ok { hasSession = true }
        LogStore.shared.log(.provisioning,
            ok ? "🔗 VK account linked (session stored in Keychain)"
               : "⚠ Could not store the VK session in the Keychain")
        return ok
    }

    /// The stored credential, or nil when no account is linked.
    /// Callers must treat the result as a bearer credential: header only, never
    /// a log line, never an error message.
    func load() -> String? { Self.storedSession() }

    /// Unlinks the account — the user's "sign out" and the recovery from a
    /// rejected session. The web-view copy goes too, so the forget is complete.
    func clear() {
        KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        hasSession = false
        Self.purgeWebCookies()
        LogStore.shared.log(.provisioning, "🔓 VK account unlinked (session removed)")
    }

    /// Re-reads the Keychain into `hasSession`. Only needed when something other
    /// than this instance changed the item (a second store instance, a fresh
    /// launch while the device was locked).
    func refresh() { hasSession = Self.hasStoredSession() }

    // MARK: Nonisolated readers (for service code)

    /// The stored credential — a cookie jar, or a legacy bare `remixsid` value —
    /// readable from any isolation domain. `VKCallRoomService` runs off
    /// MainActor and needs exactly this.
    nonisolated static func storedSession() -> String? {
        guard let raw = KeychainHelper.get(service: keychainService, account: keychainAccount)
        else { return nil }
        return normalizeStored(raw)
    }

    /// Whether an account is linked — the only fact that is safe to log.
    nonisolated static func hasStoredSession() -> Bool { storedSession() != nil }

    /// The credential for a create call: the Keychain item when it exists, else
    /// the cookie jar still sitting in the web view (a login that stored
    /// nothing because the Keychain write failed, or a fresh install on a device
    /// that still holds the web session). The jar is VERIFIED against VK before
    /// it is adopted into the Keychain: an unverified adoption once landed a
    /// dead credential in the Keychain — after which every create answered
    /// "unauthorized" and the sign-in sheet looked linked.
    nonisolated static func resolvedSession() async -> String? {
        if let stored = storedSession() { return stored }
        guard let jar = await webSessionCookie(),
              let clean = normalizeStored(jar),
              await VKCallRoomService.sessionIsValid(clean) else { return nil }
        KeychainHelper.set(clean, service: keychainService, account: keychainAccount)
        return clean
    }

    /// The `Cookie` header value for an authenticated VK call. A jar travels as
    /// the validated jar it is; a legacy bare value becomes the single
    /// `remixsid=<value>` pair it always was. Anything that is neither yields an
    /// empty header — VK answers "unauthorized" to it, and nothing unsafe is
    /// ever interpolated into a request.
    nonisolated static func cookieHeader(session: String) -> String {
        if let jar = assembleJar(from: cookiePairs(in: session)) { return jar }
        guard let bare = legacyBareValue(session) else { return "" }
        return "\(cookieName)=\(bare)"
    }

    // MARK: Web cookie store

    /// The vk.ru cookie jar currently in WebKit's persistent store, as a
    /// `Cookie`-header string, or nil when it holds no `remixsid`. The one place
    /// that touches the web view's cookie store outside the login flow. Only the
    /// jar string crosses the continuation — never the cookie objects.
    nonisolated static func webSessionCookie() async -> String? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: sessionJar(in: cookies))
            }
        }
    }

    /// Drops every vk.ru cookie from WebKit's persistent store — the web copy of
    /// the credential, purged when the user signs out. Fire-and-forget, like the
    /// deletes in YandexLoginView: the caller never blocks on WebKit.
    ///
    /// `completion`, when given, runs on the main queue once every delete has
    /// finished. The sign-in sheet reloads its page only then — a reload that
    /// raced the purge would load the old account again.
    nonisolated static func purgeWebCookies(completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let doomed = cookies.filter { isVKDomain($0.domain) }
            guard !doomed.isEmpty else {
                completion?()
                return
            }
            let group = DispatchGroup()
            for cookie in doomed {
                group.enter()
                store.delete(cookie, completionHandler: { group.leave() })
            }
            group.notify(queue: .main) { completion?() }
        }
    }

    /// PURE. `vk.ru` or a subdomain of it — the same suffix rule
    /// `isSessionCookie` applies (a jar's leading dot, `.vk.ru`, satisfies the
    /// suffix test), so `evilvk.ru` is not a VK host here either.
    nonisolated static func isVKDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d == cookieDomain || d.hasSuffix("." + cookieDomain)
    }

    // MARK: Pure helpers

    /// PURE. Reduces whatever a human or a cookie jar hands us to a bare cookie
    /// value, or nil when it cannot be one. Same rules as
    /// `YandexSessionStore.normalize`: the bare value, a `name=value` pair, or
    /// the first pair of a whole `Cookie:` line; anything that could not travel
    /// in a `Cookie` header (whitespace, controls, `;`/`,`/`"`/`\`) is refused —
    /// the value is interpolated into a request header, so a stray CR/LF would
    /// be header injection. `DELETED` — VK's cookie-deletion idiom, confirmed
    /// by live probes — is refused the same way: it "survives" every syntactic
    /// check and is worth nothing.
    nonisolated static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = cookieName + "="
        if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != deletedValue else { return nil }
        return hasOnlyCookieOctets(value) ? value : nil
    }

    /// PURE. Reduces what the Keychain holds, or what a sign-in hands over, to
    /// the credential this store keeps — or nil when it cannot be one. Two
    /// shapes are accepted:
    ///   * a cookie jar (`name=value` pairs): every pair is re-validated by the
    ///     same rules `sessionJar(in:)` applies, and `remixsid` is required;
    ///   * the legacy bare `remixsid` value earlier builds stored: the
    ///     `normalize` rules, unchanged (`legacyBareValue`).
    nonisolated static func normalizeStored(_ raw: String) -> String? {
        if let jar = assembleJar(from: cookiePairs(in: raw)) { return jar }
        return legacyBareValue(raw)
    }

    /// PURE. The credential out of a web view's cookie store: every vk.ru
    /// cookie (never a look-alike host, `evilvk.ru`) as one `Cookie`-header
    /// string, `remixsid` first, or nil when the jar holds no usable
    /// `remixsid`. See `assembleJar` for what is kept.
    nonisolated static func sessionJar(in cookies: [HTTPCookie]) -> String? {
        let pairs: [(name: String, value: String)] = cookies
            .filter { isVKDomain($0.domain) }
            .map { (name: $0.name, value: $0.value) }
        return assembleJar(from: pairs)
    }

    /// PURE. What makes one sign-in attempt different from the last: the
    /// `remixsid` value and WHICH cookies came with it (their names, sorted —
    /// the values of the others change all the time and mean nothing). The
    /// sign-in sheet uses it to ask VK about a jar once, not once a second.
    /// The key is a comparison token held in memory — never logged, never stored.
    nonisolated static func signInKey(forJar jar: String) -> String {
        let pairs = cookiePairs(in: jar)
        let session = pairs.first(where: { $0.name == cookieName })?.value ?? ""
        let names = pairs.map { $0.name }.sorted()
        return ([session] + names).joined(separator: ";")
    }

    /// PURE. How many cookies a jar carries — the one fact about its contents
    /// that is safe to log.
    nonisolated static func cookieCount(inJar jar: String) -> Int {
        cookiePairs(in: jar).count
    }

    /// PURE. Is this the VK session cookie? Name must match exactly, the value
    /// must be non-empty, and the domain must be `vk.ru` or a subdomain of it.
    nonisolated static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == cookieName, !cookie.value.isEmpty else { return false }
        return isVKDomain(cookie.domain)
    }

    /// PURE. Picks the VK session cookie out of a web view's jar.
    nonisolated static func sessionCookie(in cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { isSessionCookie($0) }
    }

    // MARK: Jar construction

    /// PURE. The legacy bare `remixsid` value in `raw`, by the `normalize`
    /// rules. A string with a `;` is a pair list, not a bare value — `normalize`
    /// would take its first pair for the value — so it only ever passes as a jar.
    nonisolated private static func legacyBareValue(_ raw: String) -> String? {
        raw.contains(";") ? nil : normalize(raw)
    }

    /// PURE. The `name=value` pairs of a `Cookie`-header string, in order. A
    /// piece without an `=` is not a pair. Nothing is validated here.
    nonisolated private static func cookiePairs(in header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { piece -> (name: String, value: String)? in
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = text.firstIndex(of: "=") else { return nil }
            return (name: String(text[..<equals]),
                    value: String(text[text.index(after: equals)...]))
        }
    }

    /// PURE. The single place a jar is built, whether from a web view's cookies
    /// or from a stored string, so both obey the same rules. In order: empty
    /// values and VK's `DELETED` tombstones are skipped; a name already seen is
    /// skipped (the first cookie wins); a name that is not an RFC 6265 token, or
    /// a value outside the cookie octets, is dropped — one odd third-party
    /// cookie must not make a real sign-in unusable, and nothing unsafe is ever
    /// emitted. A jar without a valid `remixsid` is no jar. `remixsid` leads the
    /// result; the rest keep their order: `n=v; n=v`.
    nonisolated private static func assembleJar(from pairs: [(name: String, value: String)]) -> String? {
        var seen = Set<String>()
        var sessionPair: String?
        var others: [String] = []
        for pair in pairs {
            guard !pair.value.isEmpty, pair.value != deletedValue else { continue }
            guard seen.insert(pair.name).inserted else { continue }
            guard isCookieName(pair.name), hasOnlyCookieOctets(pair.value) else { continue }
            let rendered = pair.name + "=" + pair.value
            if pair.name == cookieName { sessionPair = rendered } else { others.append(rendered) }
        }
        guard let leading = sessionPair else { return nil }
        return ([leading] + others).joined(separator: "; ")
    }

    /// PURE. RFC 6265 `token`: the visible ASCII characters except the
    /// separators `( ) < > @ , ; : \ " / [ ] ? = { }`.
    nonisolated private static func isCookieName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,   // ! # $ % & ' * + - .
                 0x30...0x39, 0x41...0x5A,                   // 0-9 A-Z
                 0x5E...0x7A, 0x7C, 0x7E:                    // ^ _ ` a-z | ~
                return true
            default:
                return false
            }
        }
    }

    /// PURE. The cookie octets a value may be made of: visible ASCII except
    /// `;`, `,`, `"` and `\`. The value is interpolated into a request header,
    /// so whitespace and controls (a stray CR/LF) are never allowed through.
    nonisolated private static func hasOnlyCookieOctets(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F &&
            scalar != ";" && scalar != "," && scalar != "\"" && scalar != "\\"
        }
    }
}
