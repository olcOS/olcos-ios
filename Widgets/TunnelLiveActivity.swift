import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - TunnelLiveActivity
//
// The live session where a glance finds it: on the Lock Screen a card with the
// state, the server, how long it has been up, the speed both ways and a graph
// of the last seconds; in the Dynamic Island a shield in the state's colour
// and the download speed, opening to the same card. The app writes every word
// and figure (TunnelActivityAttributes); this only draws them. The timer
// counts by itself between updates.

struct TunnelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TunnelActivityAttributes.self) { context in
            TunnelActivityCard(state: context.state)
                .padding(Theme.Metrics.s4)
                .activityBackgroundTint(Theme.Palette.card.opacity(0.92))
                .activitySystemActionForegroundColor(Theme.Palette.textPrimary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TunnelActivityShield(phase: state.phase)
                        .font(.title2)
                        .padding(.leading, Theme.Metrics.s1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TunnelActivityTimer(since: state.since)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.trailing, Theme.Metrics.s1)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.headline)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(state.detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TunnelActivitySpeeds(state: state, onDark: true)
                        .padding(.horizontal, Theme.Metrics.s2)
                }
            } compactLeading: {
                TunnelActivityShield(phase: state.phase)
            } compactTrailing: {
                Text(state.downShort.isEmpty ? "—" : state.downShort)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(TunnelActivityShield.color(state.phase))
                    .contentTransition(.numericText())
            } minimal: {
                TunnelActivityShield(phase: state.phase)
            }
            .keylineTint(TunnelActivityShield.color(state.phase))
        }
    }
}
