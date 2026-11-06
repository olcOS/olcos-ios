import Foundation

// MARK: - SubscriptionText
//
// The words a subscription is shown with: its name, how many of its servers
// work, and when it was last updated — as a clock time, never as an age, which
// goes stale while it sits on the screen.

enum SubscriptionText {
    /// The user's name for the list, else the name the list carries, else the
    /// ready-made list's own title, else the host it comes from — never the
    /// full link, which can carry a key.
    static func title(source: String, meta: ConnectionStore.SubscriptionMeta?) -> String {
        for candidate in [meta?.customName, meta?.name] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        let canon = ConnectionStore.canonicalSource(source)
        if let curated = CuratedLists.all.first(where: { ConnectionStore.canonicalSource($0.url) == canon }) {
            return curated.title.localized()
        }
        return URL(string: canon)?.host ?? L10n.listSubscriptionUnnamed.localized()
    }

    /// "Servers: 42 · working: 30"; the working figure only once something
    /// was checked — an unchecked list is not a list of dead servers.
    static func counts(servers: Int, working: Int, checked: Int) -> String {
        checked > 0
            ? L10n.listSubscriptionServersWorking_fmt.formatted(servers, working)
            : L10n.listSubscriptionServers_fmt.formatted(servers)
    }

    /// "Updated today at 14:32", "Updated yesterday at 22:10", "Updated
    /// 8 October at 14:32" — in the app's language, the phone's time zone.
    static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = Locale(identifier: AppLocale.current.rawValue)) -> String {
        let clock = formatter("jm", calendar: calendar, locale: locale).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.subUpdatedToday_fmt.formatted(clock)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.subUpdatedYesterday_fmt.formatted(clock)
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let day = formatter(sameYear ? "dMMMM" : "dMMMMy", calendar: calendar, locale: locale).string(from: date)
        return L10n.subUpdatedOn_fmt.formatted(day, clock)
    }

    /// A list's own refresh interval in words ("1 hour", "6 hours"), or nil.
    static func interval(_ seconds: TimeInterval,
                         locale: Locale = Locale(identifier: AppLocale.current.rawValue)) -> String? {
        guard seconds > 0 else { return nil }
        let words = DateComponentsFormatter()
        words.unitsStyle = .full
        words.maximumUnitCount = 2
        words.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3_600 ? [.hour, .minute] : [.minute]
        var calendar = Calendar.current
        calendar.locale = locale
        words.calendar = calendar
        return words.string(from: seconds)
    }

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
