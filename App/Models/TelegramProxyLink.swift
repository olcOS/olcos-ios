import Foundation

// MARK: - TelegramProxyLink
//
// Telegram is the main app that talks SOCKS5 on iOS, and adding a proxy by
// hand means typing a server, a port and maybe a login into its settings.
// Telegram's own link does it in one tap: `tg://socks?server=&port=&user=&pass=`
// opens its "Enable proxy?" sheet (https://core.telegram.org/api/links). When
// Telegram is not installed, the same query on `https://t.me/socks` opens a
// page that offers it.
//
// The link carries the local login when local SOCKS authentication is on.
// It goes straight from this app to Telegram on the same phone and is never
// logged.

enum TelegramProxyLink {
    /// The in-app proxy listens on loopback only.
    static let server = "127.0.0.1"

    static func appURL(port: Int, user: String? = nil, pass: String? = nil) -> URL? {
        url(scheme: "tg", host: "socks", path: "", port: port, user: user, pass: pass)
    }

    static func webURL(port: Int, user: String? = nil, pass: String? = nil) -> URL? {
        url(scheme: "https", host: "t.me", path: "/socks", port: port, user: user, pass: pass)
    }

    private static func url(scheme: String, host: String, path: String,
                            port: Int, user: String?, pass: String?) -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        var items = [URLQueryItem(name: "server", value: server),
                     URLQueryItem(name: "port", value: String(port))]
        if let user, !user.isEmpty, let pass, !pass.isEmpty {
            items.append(URLQueryItem(name: "user", value: user))
            items.append(URLQueryItem(name: "pass", value: pass))
        }
        components.queryItems = items
        // `+` is a literal in a query value but reads as a space to many
        // parsers; spell it out.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
