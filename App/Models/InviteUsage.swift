import Foundation

// MARK: - Invite usage
//
// What Manage server → Devices says about each invite, from the server agent's
// `GET usage` (AgentUsage): whether a device that took the invite is connected
// now, or when one last was, and how much traffic those devices moved. A
// device is the invite's when it announced `inv-<tag>` or `inv-<tag>-<its own
// name>` (DeviceIdentity.effectiveClientID), so several installs of one invite
// add up. Pure, so the view only lays it out.

struct InviteUsage: Equatable {
    /// How many device ids took the invite (installs).
    var installs: Int
    /// One of them has an open session the server heard from recently.
    var online: Bool
    /// The latest moment the server saw any of them; nil when none matched.
    var lastSeen: Date?
    /// Bytes the devices received through the server (the agent's `out`).
    var received: Int64
    /// Bytes they sent through it (the agent's `in`).
    var sent: Int64

    static let empty = InviteUsage(installs: 0, online: false, lastSeen: nil, received: 0, sent: 0)

    /// Whether `deviceID` is one the invite with this tag hands out.
    static func matches(_ deviceID: String, tag: String) -> Bool {
        let invite = DeviceIdentity.inviteClientID(tag: tag)
        return deviceID == invite || deviceID.hasPrefix(invite + "-")
    }

    /// The invite's devices in `usage`, added up.
    static func summary(tag: String, in usage: AgentUsage) -> InviteUsage {
        var result = InviteUsage.empty
        for device in usage.devices where matches(device.id, tag: tag) {
            result.installs += 1
            result.online = result.online || device.online
            if device.lastSeen > 0 {
                let seen = Date(timeIntervalSince1970: TimeInterval(device.lastSeen))
                result.lastSeen = max(result.lastSeen ?? seen, seen)
            }
            result.received = adding(result.received, device.bytesOut)
            result.sent = adding(result.sent, device.bytesIn)
        }
        return result
    }

    private static func adding(_ total: Int64, _ count: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(max(0, count))
        return overflow ? .max : sum
    }

    // MARK: Words

    /// The status line: connected now, when one last was, or not yet.
    func statusText(now: Date = Date(), calendar: Calendar = .current) -> String {
        if online { return L10n.invitesUsageOnline.localized() }
        guard let lastSeen else { return L10n.invitesUsageNever.localized() }
        return L10n.invitesUsageLastSeen_fmt.formatted(Self.clock(lastSeen, now: now, calendar: calendar))
    }

    /// What VoiceOver reads for the traffic line.
    var trafficAccessibilityText: String {
        L10n.invitesUsageTrafficA11y_fmt.formatted(Self.bytes(received), Self.bytes(sent))
    }

    /// «сегодня в 14:32», «вчера в 09:10», «12 окт. в 18:05» (with the year
    /// when it is another year), in the app language: a clock time, never an
    /// age, which would go stale on the screen.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: AppLocale.current.rawValue)
        let time: String
        switch AppLocale.current {
        case .english:
            time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        case .russian, .french:
            // Written with a two-digit hour, «09:10», as the Android app writes it:
            // the system's short style drops the zero («9:10») on recent iOS.
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "HH:mm"
            time = formatter.string(from: date)
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.invitesUsageToday_fmt.formatted(time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.clockYesterday_fmt.formatted(time)
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return L10n.clockOn_fmt.formatted(date.formatted(day), time)
    }

    /// A byte count the way Files writes one ("1,2 ГБ"), in the app language.
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatStyle(style: .file, spellsOutZero: false,
                             locale: Locale(identifier: AppLocale.current.rawValue))
            .format(max(0, count))
    }

    /// «2 устройства»: how many installs took the invite, in the app
    /// language's plural form.
    static func installsText(_ count: Int) -> String {
        let key: L10n
        switch pluralForm(count, language: AppLocale.current) {
        case .one:  key = .invitesUsageDevicesOne_fmt
        case .few:  key = .invitesUsageDevicesFew_fmt
        case .many: key = .invitesUsageDevicesMany_fmt
        }
        return key.formatted(count)
    }

    enum PluralForm: Equatable { case one, few, many }

    /// CLDR's cardinal rules for the app's languages: Russian has three forms
    /// (1, 2–4 and 5–20, by the last digits), English one and the rest, French
    /// one for 0 and 1. Only Russian has `few`.
    static func pluralForm(_ n: Int, language: AppLocale) -> PluralForm {
        switch language {
        case .russian:
            let lastDigit = n % 10, lastTwo = n % 100
            if lastDigit == 1 && lastTwo != 11 { return .one }
            if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return .few }
            return .many
        case .french:
            return n == 0 || n == 1 ? .one : .many
        case .english:
            return n == 1 ? .one : .many
        }
    }
}
