import Foundation

// MARK: - RoomRotationRule
//
// How the app replaces a protocol's rooms on its own (Settings → Room
// auto-update). There is one rule per protocol, because the protocols differ in
// why a room should ever change:
//
//   telemost                    a room dies 24 hours after it is made, so the
//                               only question is whether the app renews it
//                               ahead of time: Off or Automatic.
//   vkcalls, salutejazz, jitsi  rooms do not expire; changing one is hygiene
//                               for the days a room has to go, so the choice is
//                               a schedule: Off, every 6 or 12 hours, daily,
//                               every 3 days or weekly — and, beside it, a
//                               window in the day (RoomRotationWindow).
//   mtslink                     rooms do not expire either, and the same
//                               schedule applies — but only while the app can
//                               make a meeting at all: it replays, from inside
//                               the signed-in page, the request the owner
//                               showed it in a lesson (MTSLinkTemplate) and
//                               needs the saved sign-in. Until then the picker
//                               offers Off and says why. A rotation does not
//                               delete the old meeting: the free plan allows two
//                               permanent ones, so the owner clears old ones in
//                               the cabinet (the note under the picker says so).
//
// A protocol the app no longer offers (WB Stream) has no rule: it offers Off
// only, so it can never act.
//
// Everything here is PURE: what each picker offers, what a fresh install starts
// with, and how a stored value its protocol does not offer resolves.
// Tests/RoomRotationTests.swift pins all of it.

enum RoomRotationRule: String, CaseIterable, Identifiable {
    /// The app leaves the protocol's rooms alone.
    case off
    /// Telemost only: renew a room ahead of its 24-hour expiry, at the cheapest
    /// moment (TelemostRenewalPolicy).
    case automatic
    /// Replace a room once it is 6 hours old.
    case every6Hours = "every6h"
    /// Replace a room once it is 12 hours old.
    case every12Hours = "every12h"
    /// Replace a room once it is a day old. Earlier builds saved this word.
    case daily
    /// Replace a room once it is 3 days old.
    case every3Days = "every3d"
    /// Replace a room once it is a week old. Earlier builds saved this word.
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:          return L10n.roomRotationOff.localized()
        case .automatic:    return L10n.roomRotationAutomatic.localized()
        case .every6Hours:  return L10n.roomRotationEvery6Hours.localized()
        case .every12Hours: return L10n.roomRotationEvery12Hours.localized()
        case .daily:        return L10n.roomRotationDaily.localized()
        case .every3Days:   return L10n.roomRotationEvery3Days.localized()
        case .weekly:       return L10n.roomRotationWeekly.localized()
        }
    }

    /// Whether the rule makes the app act at all.
    var isOn: Bool { self != .off }

    /// The room age, in hours, at which a scheduled rule replaces a room; nil
    /// for the rules that are not a schedule.
    var intervalHours: Int? {
        switch self {
        case .every6Hours:     return 6
        case .every12Hours:    return 12
        case .daily:           return 24
        case .every3Days:      return 72
        case .weekly:          return 168
        case .off, .automatic: return nil
        }
    }

    /// Only a schedule has a window in the day; Telemost's Automatic keeps the
    /// service's own clock.
    var hasWindow: Bool { intervalHours != nil }

    /// What a protocol on a schedule offers, in the order the picker lists it.
    static let schedule: [RoomRotationRule] = [.off, .every6Hours, .every12Hours, .daily, .every3Days, .weekly]

    /// The compact line a Settings row shows: the rule, and its window when
    /// one applies ("Daily · at night").
    static func summary(_ rule: RoomRotationRule, window: RoomRotationWindow) -> String {
        guard rule.hasWindow, let when = window.shortTitle else { return rule.title }
        return "\(rule.title) · \(when)"
    }

    // MARK: Per protocol

    /// The protocols that have a rule, in the order Settings lists them.
    static let carriers = ["telemost", "vkcalls", "salutejazz", "mtslink", "jitsi"]

    /// What the picker of `carrier` offers, and nothing else. A protocol that
    /// is not listed in `carriers` offers only Off, so it can never act.
    static func allowed(for carrier: String,
                        mtslinkCanCreate: Bool = MTSLinkRoomService.canCreateRooms) -> [RoomRotationRule] {
        switch carrier {
        case "telemost":
            return [.off, .automatic]
        case "vkcalls", "salutejazz", "jitsi":
            return schedule
        case "mtslink":
            // A schedule only while there is something to rotate WITH: the app
            // replaces a meeting by making a new one (MTSLinkRoomService),
            // which needs the template it learned and the saved sign-in. Until
            // both exist the rule resolves to Off and the note under the
            // picker says why.
            return mtslinkCanCreate ? schedule : [.off]
        default:
            return [.off]
        }
    }

    /// What a fresh install starts with. Telemost renews by default — that is
    /// what the app has always done, and a Telemost room dies after 24 hours
    /// whatever anyone wants. Every other protocol's rooms do not expire, so
    /// nothing happens until the user asks.
    static func defaultRule(for carrier: String) -> RoomRotationRule {
        carrier == "telemost" ? .automatic : .off
    }

    /// The rule that applies: `stored` when `carrier` offers it, else the
    /// default. A value that is no longer offered (hand-edited, from another
    /// build, or the schedule of a protocol the app dropped) therefore does
    /// nothing.
    static func resolved(_ stored: RoomRotationRule?, for carrier: String,
                         mtslinkCanCreate: Bool = MTSLinkRoomService.canCreateRooms) -> RoomRotationRule {
        guard let stored,
              allowed(for: carrier, mtslinkCanCreate: mtslinkCanCreate).contains(stored) else {
            return defaultRule(for: carrier)
        }
        return stored
    }

    /// One resolved rule for every protocol in `carriers`, and no others.
    static func normalized(_ rules: [String: RoomRotationRule],
                           mtslinkCanCreate: Bool = MTSLinkRoomService.canCreateRooms) -> [String: RoomRotationRule] {
        var out: [String: RoomRotationRule] = [:]
        for carrier in carriers {
            out[carrier] = resolved(rules[carrier], for: carrier, mtslinkCanCreate: mtslinkCanCreate)
        }
        return out
    }

    /// The rules of a fresh install.
    static var defaults: [String: RoomRotationRule] { normalized([:]) }

    /// The one-line note under a protocol's picker: how its rooms behave.
    static func noteKey(for carrier: String,
                        mtslinkCanCreate: Bool = MTSLinkRoomService.canCreateRooms) -> L10n {
        switch carrier {
        case "telemost":
            return .roomRotationNoteTelemost
        case "mtslink" where !mtslinkCanCreate:
            // The picker offers Off only; this says why.
            return .roomRotationNoteMtslink
        case "mtslink":
            // Rotations leave the old meeting in the cabinet.
            return .roomRotationNoteMtslinkPlan
        default:
            return .roomRotationNoteSteady
        }
    }
}

// MARK: - RoomRotationWindow
//
// WHEN in the day a scheduled change may happen, by the phone's clock: any time
// (what every earlier build did), at night (02:00–06:00) or within one chosen
// hour. A due room outside its window waits for the next one
// (RoomRotationPolicy.decide). Persisted per protocol beside its rule; nothing
// saved, or anything no build writes, reads as any time.

enum RoomRotationWindow: Hashable, Identifiable {
    case anyTime
    case night
    /// The local hour 0–23 the change happens within.
    case hour(Int)

    static let nightStart = 2
    static let nightEnd = 6

    var id: String { stored }

    /// A chosen hour held inside the day.
    static func clampedHour(_ value: Int) -> RoomRotationWindow {
        .hour(min(max(value, 0), 23))
    }

    /// Whether the local `hourOfDay` (0–23) is inside the window.
    func contains(hourOfDay: Int) -> Bool {
        switch self {
        case .anyTime:       return true
        case .night:         return (Self.nightStart..<Self.nightEnd).contains(hourOfDay)
        case .hour(let h):   return hourOfDay == h
        }
    }

    /// What UserDefaults holds: `anytime`, `night` or `hour:3`.
    var stored: String {
        switch self {
        case .anyTime:       return "anytime"
        case .night:         return "night"
        case .hour(let h):   return "hour:\(h)"
        }
    }

    init(stored: String?) {
        switch stored {
        case "night"?:
            self = .night
        case let text? where text.hasPrefix("hour:"):
            if let h = Int(text.dropFirst("hour:".count)), (0...23).contains(h) {
                self = .hour(h)
            } else {
                self = .anyTime
            }
        default:
            self = .anyTime
        }
    }

    /// The window's part of a row's summary ("at night", "at 03:00"); nil for
    /// any time, which needs no words.
    var shortTitle: String? {
        switch self {
        case .anyTime:       return nil
        case .night:         return L10n.roomRotationWhenNightShort.localized()
        case .hour(let h):   return L10n.roomRotationWhenHourShort_fmt.formatted(Self.hourLabel(h))
        }
    }

    /// An hour on the 24-hour clock, "03:00".
    static func hourLabel(_ value: Int) -> String {
        String(format: "%02d:00", value)
    }

    /// One window for every protocol in `RoomRotationRule.carriers`, and no
    /// others; a protocol with none saved is any time.
    static func normalized(_ windows: [String: RoomRotationWindow]) -> [String: RoomRotationWindow] {
        var out: [String: RoomRotationWindow] = [:]
        for carrier in RoomRotationRule.carriers {
            out[carrier] = windows[carrier] ?? .anyTime
        }
        return out
    }

    /// The windows of a fresh install.
    static var defaults: [String: RoomRotationWindow] { normalized([:]) }
}
