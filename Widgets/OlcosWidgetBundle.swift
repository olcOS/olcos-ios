import WidgetKit
import SwiftUI

// MARK: - olcOS widgets
//
// One status widget (Home Screen, StandBy, CarPlay on iOS 26, Lock Screen),
// one traffic widget (what the session moved, the speed, its time),
// the live session's card on the Lock Screen and in the Dynamic Island, and,
// on iOS 18, one Control Centre / Lock Screen / Action button toggle. The
// buttons switch the tunnel through the intents in
// Shared/TunnelControlIntents.swift, which the system runs in the app's process.

@main
struct OlcosWidgetBundle: WidgetBundle {
    var body: some Widget {
        TunnelStatusWidget()
        TunnelTrafficWidget()
        TunnelLiveActivity()
        if #available(iOS 18.0, *) {
            TunnelControlWidget()
        }
    }
}

/// The app's language for the widget's strings: what the app last shared, or
/// the system's preference before it ever did. `AppLocale.current` reads this
/// in the extension (App/Localization/L10n.swift).
enum WidgetLanguage {
    static var current: AppLocale {
        if let code = TunnelWidgetState.sharedDefaults?.string(forKey: TunnelWidgetState.languageKey),
           let locale = AppLocale(rawValue: code) {
            return locale
        }
        return AppLocale(rawValue: AppLocale.preferredLanguage(from: Locale.preferredLanguages)) ?? .english
    }
}
