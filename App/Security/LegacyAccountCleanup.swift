import Foundation

// MARK: - LegacyAccountCleanup
//
// Credentials of features the app no longer has. Earlier versions kept them in
// the Keychain and UserDefaults; with the screens gone there is nothing left to
// sign out or delete from, so they are removed at launch (a no-op once they
// are gone, and retried on the next launch if the device was still locked).

enum LegacyAccountCleanup {
    /// The Keychain location `WBSessionStore` used to write.
    private static let wbService = "olcrtc.wb.session"
    private static let wbAccount = "wb_access_token"

    /// The control-bot registry: its JSON in UserDefaults lists the bot ids, and
    /// each bot's token sat in the Keychain under its id.
    private static let botsKey = "olcrtc_bots"
    private static let botTokenService = "olcrtc.bot.token"

    static func removeAll() {
        removeWBSession()
        removeBots()
    }

    static func removeWBSession() {
        KeychainHelper.delete(service: wbService, account: wbAccount)
    }

    static func removeBots(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: botsKey),
           let bots = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for bot in bots {
                if let id = bot["id"] as? String {
                    KeychainHelper.delete(service: botTokenService, account: id)
                }
            }
        }
        defaults.removeObject(forKey: botsKey)
    }
}
