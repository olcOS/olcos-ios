import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - TunnelActivityAttributes
//
// The live session on the Lock Screen and in the Dynamic Island. The app
// starts it when a session comes up and feeds it every couple of seconds
// (TunnelLiveActivityPublisher); the widget extension draws it
// (Widgets/TunnelLiveActivity.swift). Every word arrives already written in
// the app's language and every figure already formatted, so the extension
// needs neither the App Group nor the app's settings: it draws what it gets.

#if canImport(ActivityKit)
struct TunnelActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `TunnelWidgetState.Phase` raw value.
        var phase: String
        /// "Connected", "Connecting…" — in the app's language.
        var headline: String
        /// "Whole server · ams-1".
        var detail: String
        /// When the session came up; the timer counts from here.
        var since: Date?
        /// "4.5 Mbit/s" and "120 Kbit/s", or empty before a first reading.
        var down: String
        var up: String
        /// "4.5M" — the download for the island's narrow corner.
        var downShort: String
        /// The download speed of the last samples, oldest first, for the graph.
        var history: [Double]
    }
}
#endif

/// What a Live Activity's state says, decided in one pure place the app's
/// tests pin.
enum TunnelActivityContent {
    /// How many download samples the graph keeps.
    static let historyLength = 24

    /// PURE. The history with `sample` appended, at most `historyLength` long.
    static func appending(_ sample: Double, to history: [Double]) -> [Double] {
        Array((history + [max(0, sample.isFinite ? sample : 0)]).suffix(historyLength))
    }

    /// PURE. Each point's height in 0…1 against the busiest one.
    static func normalized(_ history: [Double]) -> [Double] {
        let peak = history.max() ?? 0
        guard peak > 0 else { return history.map { _ in 0 } }
        return history.map { max(0, $0) / peak }
    }
}
