import SwiftUI

// MARK: - The live session's card
//
// What the Live Activity draws (Widgets/TunnelLiveActivity.swift), kept here so
// the app compiles it too and its screenshots can show it. Every word and
// figure arrives in TunnelActivityAttributes.ContentState.

/// The Lock Screen card.
struct TunnelActivityCard: View {
    let state: TunnelActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            HStack(alignment: .center, spacing: Theme.Metrics.s3) {
                TunnelActivityShield(phase: state.phase)
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .background(TunnelActivityShield.color(state.phase).opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline)
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(state.detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Metrics.s2)
                TunnelActivityTimer(since: state.since)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            TunnelActivitySpeeds(state: state, onDark: false)
        }
    }
}

/// Down and up, and the graph of the last seconds' download.
struct TunnelActivitySpeeds: View {
    let state: TunnelActivityAttributes.ContentState
    let onDark: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("↓ \(state.down.isEmpty ? "—" : state.down)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(onDark ? Color.white : Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
                Text("↑ \(state.up.isEmpty ? "—" : state.up)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(onDark ? Color.white.opacity(0.7) : Theme.Palette.textSecondary)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: Theme.Metrics.s2)
            TunnelActivityGraph(points: TunnelActivityContent.normalized(state.history),
                                color: TunnelActivityShield.color(state.phase))
                .frame(width: 110, height: 34)
        }
    }
}

/// Bars for the last seconds, the newest on the right.
struct TunnelActivityGraph: View {
    let points: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(points.count, 1)
            let gap: CGFloat = 2
            let width = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(color.opacity(0.35 + 0.65 * value))
                        .frame(width: width, height: max(3, geo.size.height * value))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
        }
        .accessibilityHidden(true)
    }
}

/// How long the session has been up; nothing before it is.
struct TunnelActivityTimer: View {
    let since: Date?

    var body: some View {
        if let since {
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80, alignment: .trailing)
        }
    }
}

/// A shield in the state's colour.
struct TunnelActivityShield: View {
    let phase: String

    var body: some View {
        Image(systemName: Self.symbol(phase))
            .foregroundStyle(Self.color(phase))
    }

    static func symbol(_ phase: String) -> String {
        switch TunnelWidgetState.Phase(rawValue: phase) {
        case .on:                   return "checkmark.shield.fill"
        case .connecting, .waiting: return "shield.lefthalf.filled"
        case .failed:               return "exclamationmark.shield.fill"
        case .off, .none:           return "shield.slash"
        }
    }

    static func color(_ phase: String) -> Color {
        switch TunnelWidgetState.Phase(rawValue: phase) {
        case .on:                   return Theme.Palette.green
        case .connecting, .waiting: return Theme.Palette.amber
        case .failed:               return Theme.Palette.red
        case .off, .none:           return Theme.Palette.textSecondary
        }
    }
}
