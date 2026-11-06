import WidgetKit
import SwiftUI
import AppIntents

// MARK: - TunnelTrafficWidget
//
// The session in figures: what came in and went out since it started, the
// last download speed and how long it has been up, with the same power
// button as the status widget. The app writes the figures already formatted
// (TunnelWidgetPublisher) and reloads this widget when they change, about
// once a minute while it is open; the face says when they were read, so an
// older figure is never passed off as now. The speed live, second by second,
// is the Live Activity's job.

struct TunnelTrafficWidget: Widget {
    static let kind = TunnelWidgetState.trafficKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TunnelStatusProvider()) { entry in
            TunnelTrafficView(entry: entry)
        }
        .configurationDisplayName(L10n.widgetTrafficName.localized())
        .description(L10n.widgetTrafficDescription.localized())
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct TunnelTrafficView: View {
    let entry: TunnelStatusEntry

    @Environment(\.widgetFamily) private var family

    private var model: TunnelWidgetDisplay.Model {
        TunnelWidgetDisplay.model(for: entry.state, now: entry.date)
    }

    /// Figures only for a live session the app vouches for.
    private var figures: TunnelWidgetState? {
        guard let state = entry.state, model.tone == .on, state.trafficDown != nil else { return nil }
        return state
    }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .accessoryRectangular {
                    Color.clear
                } else {
                    TunnelWidgetBackground(tone: model.tone)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .systemMedium:         medium
        default:                    small
        }
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            header
            Spacer(minLength: 0)
            if let state = figures {
                figureLine(downGlyph(state), state.trafficDown ?? "—", big: true)
                if let up = state.trafficUp { figureLine("arrow.up", up, big: false) }
                footnote(state)
            } else {
                Text(model.headline)
                    .font(Theme.Typography.title.weight(.bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .invalidatableContent()
                Spacer(minLength: Theme.Metrics.s1)
                powerCapsule
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s4) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                header
                Spacer(minLength: 0)
                if let state = figures {
                    figureLine(downGlyph(state), state.trafficDown ?? "—", big: true)
                    if let up = state.trafficUp { figureLine("arrow.up", up, big: false) }
                    footnote(state)
                } else {
                    Text(model.headline)
                        .font(Theme.Typography.title.weight(.bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .invalidatableContent()
                    Text(L10n.widgetTrafficNone.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            powerCircle
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Metrics.s1) {
                Text(TunnelWidgetDisplay.brand)
                    .font(Theme.Typography.captionStrong)
                if let since = model.since {
                    Text(since, style: .timer)
                        .font(Theme.Typography.caption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
            }
            if let state = figures {
                Text("\(state.trafficUp == nil ? "↕" : "↓") \(state.trafficDown ?? "—")")
                    .font(Theme.Typography.bodyStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let up = state.trafficUp {
                    Text("↑ \(up)")
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                }
            } else {
                Text(model.headline)
                    .font(Theme.Typography.bodyStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .widgetAccentable()
    }

    // MARK: Pieces

    /// The brand, and how long the session has been up.
    private var header: some View {
        HStack(spacing: Theme.Metrics.s1) {
            Image(systemName: "arrow.up.arrow.down")
                .font(Theme.Typography.label)
                .foregroundStyle(model.tone == .on ? Theme.Palette.green : Theme.Palette.textSecondary)
            Text(TunnelWidgetDisplay.brand)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
            if let since = model.since {
                Text(since, style: .timer)
                    .font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            }
        }
    }

    /// The in-app proxy's one "≈" figure counts both ways; the arrow says so.
    private func downGlyph(_ state: TunnelWidgetState) -> String {
        state.trafficUp == nil ? "arrow.up.arrow.down" : "arrow.down"
    }

    private func figureLine(_ systemImage: String, _ value: String, big: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s1) {
            Image(systemName: systemImage)
                .font((big ? Theme.Typography.title : Theme.Typography.body).weight(.bold))
                .foregroundStyle(big ? Theme.Palette.green : Theme.Palette.textSecondary)
            Text(value)
                .font((big ? Theme.Typography.title : Theme.Typography.bodyStrong).weight(.bold).monospacedDigit())
                .foregroundStyle(big ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
    }

    /// The speed when it was read, and when that was.
    private func footnote(_ state: TunnelWidgetState) -> some View {
        let parts: [String] = [
            state.trafficRate.map { L10n.widgetTrafficRate_fmt.formatted($0) },
            state.trafficAt.map { L10n.widgetTrafficAt_fmt.formatted($0.formatted(date: .omitted, time: .shortened)) },
        ].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    /// The small widget's button when there are no figures to show.
    private var powerCapsule: some View {
        intentButton {
            HStack(spacing: Theme.Metrics.s1) {
                Image(systemName: "power")
                    .font(Theme.Typography.label.weight(.bold))
                Text(TunnelWidgetDisplay.title(for: model.action))
                    .font(Theme.Typography.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isCallToAction ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(isCallToAction ? AnyShapeStyle(Theme.Signal.actionGradient) : AnyShapeStyle(Theme.Palette.fill),
                        in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var powerCircle: some View {
        intentButton {
            VStack(spacing: Theme.Metrics.s1) {
                ZStack {
                    Circle()
                        .fill(isCallToAction ? AnyShapeStyle(Theme.Signal.actionGradient)
                                             : AnyShapeStyle(Theme.Palette.fill))
                    Image(systemName: "power")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(isCallToAction ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
                }
                .frame(width: 64, height: 64)
                Text(TunnelWidgetDisplay.title(for: model.action))
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
    }

    private var isCallToAction: Bool { model.action != .turnOff }

    @ViewBuilder
    private func intentButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        switch model.action {
        case .turnOn:  Button(intent: SetTunnelRunningIntent(value: true), label: label)
        case .turnOff: Button(intent: SetTunnelRunningIntent(value: false), label: label)
        case .toggle:  Button(intent: ToggleTunnelIntent(), label: label)
        }
    }
}

#if DEBUG
extension TunnelWidgetState {
    /// The gallery's traffic sample.
    static func previewWithTraffic(now: Date) -> TunnelWidgetState {
        var state = preview(now: now)
        state.trafficDown = "1.2 GB"
        state.trafficUp = "85 MB"
        state.trafficRate = "4.5 Mbit/s"
        state.trafficAt = now
        return state
    }
}

#Preview("olcOS traffic — small", as: .systemSmall) {
    TunnelTrafficWidget()
} timeline: {
    TunnelStatusEntry(date: Date(), state: TunnelWidgetState.previewWithTraffic(now: Date()))
    TunnelStatusEntry(date: Date(), state: nil)
}
#endif
