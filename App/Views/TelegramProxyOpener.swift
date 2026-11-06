import SwiftUI

// MARK: - Telegram hand-off
//
// Settings → «В Telegram» is the one place that offers it: proxy mode is not a
// device-wide VPN, and Telegram takes the local SOCKS5 proxy in one tap.

enum TelegramProxyOpener {
    /// Hands the local SOCKS5 proxy to Telegram in one tap (its own "Enable
    /// proxy?" sheet) or, without Telegram installed, to the t.me page that
    /// offers it. The link is never logged: it may carry the local login.
    @MainActor
    static func open(port: Int, settings: SettingsStore) {
        let auth = settings.localSocksAuthEnabled
        let user = auth ? settings.localSocksUser : nil
        let pass = auth ? settings.localSocksPass : nil
        guard let app = TelegramProxyLink.appURL(port: port, user: user, pass: pass) else { return }
        let web = TelegramProxyLink.webURL(port: port, user: user, pass: pass)
        UIApplication.shared.open(app) { opened in
            if !opened, let web { UIApplication.shared.open(web) }
        }
    }
}
