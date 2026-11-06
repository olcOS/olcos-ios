import Foundation
import WebKit

// MARK: - YandexSessionStore (#463)
//
// Keychain home of the ONE credential that lets the phone create a Yandex
// Telemost room: the `Session_id` cookie of a signed-in Yandex account.
//
// Why this file exists
// --------------------
// Telemost rooms expire on a 24-hour clock, and the only way to mint a new one
// is an authenticated POST to the Telemost front API (see TelemostRoomService).
// The whole credential for that POST is `Session_id` — no CSRF token, no
// signing. Nobody automates the Yandex password (passport.yandex.ru has
// first-class captcha states), so the proven pattern is: the human signs in
// ONCE in a real web view, the app lifts that cookie and reuses it.
//
// Why the handling is paranoid
// ----------------------------
// A live `Session_id` is a bearer credential for the user's ENTIRE Yandex
// identity — Mail, Disk, Pay, personal data — usable without the password and
// past 2FA. So, exactly like the connection key and the SSH password:
//
//   * Keychain ONLY. Never UserDefaults, never a file, never a backup.
//   * Never logged — not the value, not a prefix, not a length. The only thing
//     this file ever writes to the log is WHETHER a session exists.
//   * Never put in an error message or an exported diagnostic. `hasSession` is
//     the only fact that leaves this type without the caller asking for the
//     value outright.
//
// The web view's copy
// -------------------
// The sign-in sheet deletes the cookies it lifts, but a sheet closed before the
// sign-in finished, or a sign-in on a Yandex host the app does not read, leaves
// an account signed in inside the web view that the Keychain knows nothing
// about. `purgeWebCookies` is the way out of that copy and `clear()` runs it, so
// forgetting the account is complete from both ends.
//
// Shape
// -----
// An `ObservableObject` so a view can bind to `hasSession` ("account linked"),
// plus `nonisolated static` readers so nonisolated service code
// (TelemostRoomService) can fetch the cookie without hopping to MainActor.
// There is deliberately NO shared singleton: the store owns no state beyond the
// published flag, so a view can create its own with `@StateObject` and the
// service reads the Keychain directly.

@MainActor
final class YandexSessionStore: ObservableObject {

    // MARK: Naming

    /// The cookie that IS the credential (`kulikov0/whitelist-bypass`'s
    /// `YANDEX_AUTH_COOKIE`, and what telemost.yandex.ru itself sends).
    nonisolated static let cookieName = "Session_id"

    /// Registrable domain the cookie is scoped to. Used to pick the right cookie
    /// out of a web view's jar — matching on the name alone would accept a
    /// same-named cookie from an unrelated host.
    nonisolated static let cookieDomain = "yandex.ru"

    /// The hosts a Yandex sign-in can leave cookies and page storage on: the main
    /// domain, the international and short ones and the `yandex.net` service
    /// hosts. This is what the app may delete from the web view — not the scope
    /// of the credential, which stays `cookieDomain`.
    nonisolated static let webDomains: [String] = [cookieDomain, "yandex.com", "ya.ru", "yandex.net"]

    // Follows the house convention for secret services:
    // `olcrtc.serverhost.password`, `olcrtc.connection.key`.
    nonisolated private static let keychainService = "olcrtc.yandex.session"
    nonisolated private static let keychainAccount = "Session_id"
    /// `sessionid2`, the HTTPS-only twin passport issues with `Session_id`.
    nonisolated static let secureTwinName = "sessionid2"
    nonisolated private static let secureTwinAccount = "sessionid2"

    // MARK: Observable state

    /// Whether an account is linked. The ONLY thing about the credential that is
    /// ever published, logged or shown.
    @Published private(set) var hasSession: Bool = false

    init() {
        hasSession = Self.hasStoredSession()
    }

    // MARK: Read / write

    /// Stores the `Session_id` cookie value, replacing any previous one.
    ///
    /// A value that does not survive `normalize` is REJECTED without touching
    /// what is already stored — a bad paste must never silently unlink a working
    /// account. Returns whether the Keychain write happened.
    @discardableResult
    func save(_ sessionID: String) -> Bool {
        guard let value = Self.normalize(sessionID) else {
            LogStore.shared.log(.provisioning,
                "⚠ Yandex sign-in ignored: the value is not a usable session cookie")
            return false
        }
        let ok = KeychainHelper.set(value,
                                    service: Self.keychainService,
                                    account: Self.keychainAccount)
        if ok { hasSession = true }
        LogStore.shared.log(.provisioning,
            ok ? "🔗 Yandex account linked (session stored in Keychain)"
               : "⚠ Could not store the Yandex session in the Keychain")
        return ok
    }

    /// Convenience for the web-view login: takes the cookie object straight from
    /// `WKHTTPCookieStore` / `HTTPCookieStorage`. Rejects anything that is not
    /// the Yandex `Session_id`.
    @discardableResult
    func save(cookie: HTTPCookie) -> Bool {
        guard Self.isSessionCookie(cookie) else { return false }
        return save(cookie.value)
    }

    /// The stored cookie value, or nil when no account is linked.
    /// Callers must treat the result as a bearer credential: header only, never
    /// a log line, never an error message.
    func load() -> String? { Self.storedSession() }

    /// Unlinks the account — the user's "sign out" and the recovery from a 401.
    /// The web-view copy goes too, so the forget is complete.
    func clear() {
        KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        KeychainHelper.delete(service: Self.keychainService, account: Self.secureTwinAccount)
        hasSession = false
        Self.purgeWebCookies()
        LogStore.shared.log(.provisioning, "🔓 Yandex account unlinked (session removed)")
    }

    /// Re-reads the Keychain into `hasSession`. Only needed when something other
    /// than this instance changed the item (a second store instance, a fresh
    /// launch while the device was locked).
    func refresh() { hasSession = Self.hasStoredSession() }

    // MARK: Nonisolated readers (for service code)

    /// The stored cookie value, readable from any isolation domain.
    /// `TelemostRoomService` runs off MainActor and needs exactly this.
    nonisolated static func storedSession() -> String? {
        guard let raw = KeychainHelper.get(service: keychainService, account: keychainAccount)
        else { return nil }
        return normalize(raw)
    }

    /// Whether an account is linked — the only fact that is safe to log.
    nonisolated static func hasStoredSession() -> Bool { storedSession() != nil }

    /// Stores (or, for nil, removes) the `sessionid2` that came with the
    /// session. Same Keychain service, same rules as `Session_id`.
    nonisolated static func storeSecureTwin(_ raw: String?) {
        if let raw, let value = normalize(raw) {
            KeychainHelper.set(value, service: keychainService, account: secureTwinAccount)
        } else {
            KeychainHelper.delete(service: keychainService, account: secureTwinAccount)
        }
    }

    nonisolated static func storedSecureTwin() -> String? {
        KeychainHelper.get(service: keychainService, account: secureTwinAccount).flatMap(normalize)
    }

    /// The `Cookie` header value for an authenticated Telemost call.
    nonisolated static func cookieHeader(session: String, secureTwin: String?) -> String {
        var header = "\(cookieName)=\(session)"
        if let secureTwin { header += "; \(secureTwinName)=\(secureTwin)" }
        return header
    }

    // MARK: Web cookie store

    /// Drops the web view's copy of a Yandex sign-in: every cookie of the Yandex
    /// hosts and their page storage. Fire-and-forget, like the deletes in
    /// YandexLoginView: the caller never blocks on WebKit.
    ///
    /// `completion`, when given, runs on the main queue once everything has been
    /// removed, so the sign-in sheet can reload its page without racing the
    /// purge — a reload that raced it would load the old account again.
    ///
    /// Cookies are not the only place a page can keep a sign-in: WB Stream's
    /// page keeps its token in page storage (localStorage / IndexedDB), which a
    /// cookie delete cannot reach. The site data of the Yandex hosts goes too.
    /// Only those records, never the whole shared store: VK and WB Stream sit in
    /// it as well.
    nonisolated static func purgeWebCookies(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        let store = dataStore.httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where isYandexDomain(cookie.domain) {
                group.enter()
                store.delete(cookie, completionHandler: { group.leave() })
            }
            group.enter()
            DispatchQueue.main.async {
                let types = WKWebsiteDataStore.allWebsiteDataTypes()
                dataStore.fetchDataRecords(ofTypes: types) { records in
                    let yandex = records.filter { isYandexDomain($0.displayName) }
                    guard !yandex.isEmpty else {
                        group.leave()
                        return
                    }
                    dataStore.removeData(ofTypes: types, for: yandex) { group.leave() }
                }
            }
            group.notify(queue: .main) { completion?() }
        }
    }

    // MARK: Pure helpers

    /// PURE. Reduces whatever a human or a cookie jar hands us to a bare cookie
    /// value, or nil when it cannot be one.
    ///
    /// Accepts, in order of forgiveness:
    ///   * `3:1712…` — the value as the web view reports it;
    ///   * `Session_id=3:1712…` — a pasted name=value pair;
    ///   * `Session_id=3:1712…; yandexuid=…` — a pasted whole `Cookie:` line,
    ///     of which only the first pair is kept.
    ///
    /// Rejects anything that could not travel in a `Cookie` header: empty after
    /// trimming, or carrying whitespace / control characters / `;` / `,` / `"`
    /// / `\` (RFC 6265 cookie-octet). That guard is not cosmetic — the value is
    /// interpolated into a request header, so a stray CR/LF would be header
    /// injection.
    nonisolated static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = cookieName + "="
        if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let usable = value.unicodeScalars.allSatisfy { scalar in
            // > 0x20 (not >=) drops space and every control character, including
            // CR/LF; < 0x7F drops DEL and everything non-ASCII.
            scalar.value > 0x20 && scalar.value < 0x7F &&
            scalar != ";" && scalar != "," && scalar != "\"" && scalar != "\\"
        }
        return usable ? value : nil
    }

    /// PURE. Is this the Yandex session cookie? Name must match exactly, the
    /// value must be non-empty, and the domain must be `yandex.ru` or a subdomain
    /// of it — `hasSuffix("." + domain)` so a look-alike host such as
    /// `evilyandex.ru` can never pass.
    nonisolated static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == cookieName, !cookie.value.isEmpty else { return false }
        let domain = cookie.domain.lowercased()
        return domain == cookieDomain || domain.hasSuffix("." + cookieDomain)
    }

    /// PURE. A Yandex host: one of `webDomains` or a subdomain of one. The dot
    /// in the suffix test keeps look-alikes out — `evilyandex.ru`, and `maya.ru`
    /// for `ya.ru` — while a cookie jar's leading dot (`.yandex.ru`) and the bare
    /// registrable name of a site-data record (`yandex.ru`) both satisfy it.
    /// It decides what may be deleted from the web view; the credential is still
    /// taken from `cookieDomain` alone (`isSessionCookie`).
    nonisolated static func isYandexDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return webDomains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// PURE. Picks the Yandex session cookie out of a web view's jar.
    /// Passport sets it on `.yandex.ru`, so one pass over the whole jar is all
    /// the login sheet needs.
    nonisolated static func sessionCookie(in cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { isSessionCookie($0) }
    }

    /// PURE. The `sessionid2` twin from the same jar, under the same domain rule.
    nonisolated static func secureTwinCookie(in cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { cookie in
            guard cookie.name == secureTwinName, !cookie.value.isEmpty,
                  !cookie.value.hasPrefix("noauth") else { return false }
            let domain = cookie.domain.lowercased()
            return domain == cookieDomain || domain.hasSuffix("." + cookieDomain)
        }
    }
}
