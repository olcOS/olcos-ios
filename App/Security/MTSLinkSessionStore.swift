import Foundation
import WebKit

// MARK: - MTSLinkSessionStore
//
// Keychain home of the ONE credential that lets the phone make an MTS Link
// meeting itself: the my.mts-link.ru cookie jar of the owner's signed-in
// account (MTSLinkRoomService). Same pattern as VKSessionStore, which is in
// turn the YandexSessionStore pattern: nobody automates the password, so the
// human signs in ONCE in a real web view (MTSLinkLoginView) and the app
// reuses the cookies that sign-in produced.
//
// Why the WHOLE jar and not one cookie
// ------------------------------------
// Unlike VK there is no one cookie name known to stand for the session — the
// capture sheet exists precisely to learn such shapes. So the credential is
// every my.mts-link.ru cookie the web view holds, as one `Cookie`-header
// string, in the order the store read them. A jar with no cookies at all is
// no session.
//
// Why the handling is paranoid
// ----------------------------
// A live cabinet session is a bearer credential for the owner's whole MTS Link
// identity — meetings, recordings, billing. So, exactly like the VK session:
//
//   * Keychain ONLY. Never UserDefaults, never a file, never a backup.
//   * Never logged — not the jar, not a cookie value, not a length. The only
//     facts that may reach a log are WHETHER a session exists and how many
//     cookies a jar carries (`cookieCount`).
//   * Never put in an error message or an exported diagnostic.
//   * The jar is rebuilt from validated pairs every time it is stored, read or
//     put into a request: a name that is not an RFC 6265 token, or a value
//     that could not travel in a `Cookie` header, is dropped — so a stray
//     CR/LF can never become header injection.
//
// Shape: like VKSessionStore — an `ObservableObject` so a view binds to
// `hasSession`, plus `nonisolated static` readers for the nonisolated service
// code (MTSLinkRoomService). No shared singleton.

@MainActor
final class MTSLinkSessionStore: ObservableObject {

    // MARK: Naming

    /// Registrable domain the cookies are scoped to — `my.mts-link.ru` and
    /// `mts-link.ru` are one service. Used to pick the right cookies out of a
    /// web view's jar, never a name-only match (a same-named cookie from an
    /// unrelated host must never be adopted).
    nonisolated static let cookieDomain = "mts-link.ru"

    // House convention: `olcrtc.vk.session`, `olcrtc.yandex.session`.
    nonisolated private static let keychainService = "olcrtc.mtslink.session"
    nonisolated private static let keychainAccount = "session"

    // MARK: Observable state

    /// Whether an account is linked. The ONLY thing about the credential that
    /// is ever published, logged or shown.
    @Published private(set) var hasSession: Bool = false

    init() {
        hasSession = Self.hasStoredSession()
    }

    // MARK: Read / write

    /// Stores the cookie jar the sign-in sheet hands over, replacing any
    /// previous one. A value that does not survive `normalizeStored` is
    /// REJECTED without touching what is already stored — a bad paste must
    /// never silently unlink a working account. Returns whether the Keychain
    /// write happened.
    @discardableResult
    func save(_ session: String) -> Bool {
        guard let value = Self.normalizeStored(session) else {
            LogStore.shared.log(.provisioning,
                "⚠ MTS Link sign-in ignored: the value is not a usable cookie jar")
            return false
        }
        let ok = KeychainHelper.set(value,
                                    service: Self.keychainService,
                                    account: Self.keychainAccount)
        if ok { hasSession = true }
        LogStore.shared.log(.provisioning,
            ok ? "🔗 MTS Link account linked (session stored in Keychain)"
               : "⚠ Could not store the MTS Link session in the Keychain")
        return ok
    }

    /// The stored credential, or nil when no account is linked. Callers must
    /// treat the result as a bearer credential: header only, never a log line,
    /// never an error message.
    func load() -> String? { Self.storedSession() }

    /// Unlinks the account — the user's "sign out" and the recovery from a
    /// rejected session. The web-view copy goes too, so the forget is complete.
    func clear() {
        KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        hasSession = false
        Self.purgeWebCookies()
        LogStore.shared.log(.provisioning, "🔓 MTS Link account unlinked (session removed)")
    }

    /// Re-reads the Keychain into `hasSession`.
    func refresh() { hasSession = Self.hasStoredSession() }

    // MARK: Nonisolated readers (for service code)

    /// The stored cookie jar, readable from any isolation domain.
    /// `MTSLinkRoomService` runs off MainActor and needs exactly this.
    nonisolated static func storedSession() -> String? {
        guard let raw = KeychainHelper.get(service: keychainService, account: keychainAccount)
        else { return nil }
        return normalizeStored(raw)
    }

    /// Whether an account is linked — the only fact that is safe to log.
    nonisolated static func hasStoredSession() -> Bool { storedSession() != nil }

    /// The credential for a create call: the Keychain item when it exists, else
    /// the cookie jar still sitting in the web view (a login that stored
    /// nothing because the Keychain write failed). As in VKSessionStore, the
    /// jar is VERIFIED against the service before it is adopted into the
    /// Keychain — an unverified adoption can land a dead credential there and
    /// make every later create fail while the sheet looks linked.
    nonisolated static func resolvedSession() async -> String? {
        if let stored = storedSession() { return stored }
        guard let jar = await webSessionCookie(),
              let clean = normalizeStored(jar),
              await MTSLinkRoomService.sessionIsValid(clean) else { return nil }
        KeychainHelper.set(clean, service: keychainService, account: keychainAccount)
        return clean
    }

    /// The `Cookie` header value for an authenticated MTS Link call. A jar
    /// travels as the validated jar it is; anything else yields an empty
    /// header — and nothing unsafe is ever interpolated into a request.
    nonisolated static func cookieHeader(session: String) -> String {
        assembleJar(from: cookiePairs(in: session)) ?? ""
    }

    // MARK: Web cookie store

    /// The mts-link.ru cookie jar currently in WebKit's persistent store, as a
    /// `Cookie`-header string, or nil when it holds none. The one place that
    /// touches the web view's cookie store outside the login flow. Only the
    /// jar string crosses the continuation — never the cookie objects.
    nonisolated static func webSessionCookie() async -> String? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: sessionJar(in: cookies))
            }
        }
    }

    /// Drops every mts-link.ru cookie from WebKit's persistent store — the web
    /// copy of the credential, purged when the user signs out. Fire-and-forget,
    /// like the deletes in VKSessionStore; `completion`, when given, runs on
    /// the main queue once every delete has finished (the sign-in sheet
    /// reloads its page only then).
    nonisolated static func purgeWebCookies(completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let doomed = cookies.filter { isMTSDomain($0.domain) }
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

    /// PURE. `mts-link.ru` or a subdomain of it — a leading dot (`.mts-link.ru`)
    /// satisfies the suffix test, a look-alike (`evilmts-link.ru`) does not.
    nonisolated static func isMTSDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d == cookieDomain || d.hasSuffix("." + cookieDomain)
    }

    // MARK: Pure helpers

    /// PURE. Reduces what the Keychain holds, or what a sign-in hands over, to
    /// the credential this store keeps — or nil when it cannot be one. Two
    /// shapes are accepted: a cookie jar (`name=value` pairs) and a lone
    /// cookie value with no name, which becomes that pair under the name
    /// `session` (the app cannot know the service's cookie name yet — the
    /// capture sheet is how that is learned).
    nonisolated static func normalizeStored(_ raw: String) -> String? {
        if let jar = assembleJar(from: cookiePairs(in: raw)) { return jar }
        let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bare.isEmpty, !bare.contains(";"), hasOnlyCookieOctets(bare) else { return nil }
        return assembleJar(from: [("session", bare)])
    }

    /// PURE. The credential out of a web view's cookie store: every mts-link.ru
    /// cookie (never a look-alike host) as one `Cookie`-header string, or nil
    /// when the jar holds none.
    nonisolated static func sessionJar(in cookies: [HTTPCookie]) -> String? {
        let pairs: [(name: String, value: String)] = cookies
            .filter { isMTSDomain($0.domain) }
            .map { (name: $0.name, value: $0.value) }
        return assembleJar(from: pairs)
    }

    /// PURE. How many cookies a jar carries — the one fact about its contents
    /// that is safe to log.
    nonisolated static func cookieCount(inJar jar: String) -> Int {
        cookiePairs(in: jar).count
    }

    /// PURE. What makes one sign-in attempt different from the last: WHICH
    /// cookies came with it (their names, sorted) and the length of each value
    /// — never a value itself. The sign-in sheet uses it to ask the service
    /// about a jar once, not once a second. Held in memory, never logged.
    nonisolated static func signInKey(forJar jar: String) -> String {
        cookiePairs(in: jar)
            .map { "\($0.name):\($0.value.count)" }
            .sorted()
            .joined(separator: ";")
    }

    // MARK: Jar construction

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
    /// or from a stored string, so both obey the same rules: empty values are
    /// skipped, the first cookie of a name wins, and a name that is not an RFC
    /// 6265 token or a value outside the cookie octets is dropped — one odd
    /// third-party cookie must not make a real sign-in unusable, and nothing
    /// unsafe is ever emitted. Unlike VKSessionStore there is no one cookie
    /// the jar must carry: any mts-link.ru cookie is part of the session until
    /// the service's own shape is known. `n=v; n=v`.
    nonisolated private static func assembleJar(from pairs: [(name: String, value: String)]) -> String? {
        var seen = Set<String>()
        var kept: [String] = []
        for pair in pairs {
            guard !pair.value.isEmpty else { continue }
            guard seen.insert(pair.name).inserted else { continue }
            guard isCookieName(pair.name), hasOnlyCookieOctets(pair.value) else { continue }
            kept.append(pair.name + "=" + pair.value)
        }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
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
    /// `;`, `,`, `"` and `\`. The value travels in a request header, so
    /// whitespace and controls (a stray CR/LF) are never allowed through.
    nonisolated private static func hasOnlyCookieOctets(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F &&
            scalar != ";" && scalar != "," && scalar != "\"" && scalar != "\\"
        }
    }
}
