import WidgetKit
import SwiftUI
import AppIntents

// MARK: - TunnelStatusWidget
//
// The small widget is the one CarPlay (iOS 26) and StandBy show: there the
// background is removed and the text is read from a distance, so the face is
// one word of state, one line of route and one big button. The Lock Screen
// gets a round button and a three-line card. Every button sends an intent the
// app runs (Shared/TunnelControlIntents.swift); the word comes from
// `TunnelWidgetDisplay`, which never claims a session nobody re-confirmed.

struct TunnelStatusWidget: Widget {
    static let kind = "io.github.hotelk52339.olcos.widget.tunnel"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TunnelStatusProvider()) { entry in
            TunnelStatusView(entry: entry)
        }
        .configurationDisplayName(TunnelWidgetDisplay.brand)
        .description(L10n.widgetDescription.localized())
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TunnelStatusEntry: TimelineEntry {
    let date: Date
    /// nil: nothing shared yet (no App Group, or the app never wrote).
    let state: TunnelWidgetState?
}

struct TunnelStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TunnelStatusEntry {
        TunnelStatusEntry(date: Date(), state: TunnelWidgetState.preview(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (TunnelStatusEntry) -> Void) {
        let now = Date()
        // The gallery shows the widget at work, not this phone's state.
        let state: TunnelWidgetState? = context.isPreview
            ? TunnelWidgetState.preview(now: now)
            : TunnelWidgetState.load()
        completion(TunnelStatusEntry(date: now, state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TunnelStatusEntry>) -> Void) {
        let now = Date()
        let state = TunnelWidgetState.load()
        var entries = [TunnelStatusEntry(date: now, state: state)]
        // An engaged claim lapses when nobody re-confirms it: draw the
        // unconfirmed face at that moment.
        if let state, state.phase.isEngaged {
            let lapse = state.confirmedAt.addingTimeInterval(TunnelWidgetState.confirmWindow)
            if lapse > now { entries.append(TunnelStatusEntry(date: lapse, state: state)) }
        }
        let next = Self.nextRead(after: now, state: state)
        completion(Timeline(entries: entries, policy: next.map { .after($0) } ?? .never))
    }

    /// When to read the shared state again. The app reloads the widget while
    /// it runs; the packet tunnel only writes, so a change made while the app
    /// sleeps (a VPN switched off in Settings, a start finishing) is picked up
    /// here: soon while a connection is in flight, every half hour otherwise.
    /// Nothing to re-read without a shared container.
    static func nextRead(after now: Date, state: TunnelWidgetState?) -> Date? {
        guard let state else { return nil }
        switch state.phase {
        case .connecting, .waiting:
            return now.addingTimeInterval(90)
        case .on:
            let lapse = state.confirmedAt.addingTimeInterval(TunnelWidgetState.confirmWindow)
            return max(now.addingTimeInterval(60), min(lapse, now.addingTimeInterval(TunnelWidgetState.confirmWindow)))
        case .off, .failed:
            return now.addingTimeInterval(TunnelWidgetState.confirmWindow)
        }
    }
}

extension TunnelWidgetState {
    /// The gallery's sample: a session an hour in.
    static func preview(now: Date) -> TunnelWidgetState {
        TunnelWidgetState(phase: .on, service: "Xray", route: "REALITY · ams-1", mode: "vpn",
                          since: now.addingTimeInterval(-3_725), confirmedAt: now)
    }
}

// MARK: - Views

struct TunnelStatusView: View {
    let entry: TunnelStatusEntry

    @Environment(\.widgetFamily) private var family

    private var model: TunnelWidgetDisplay.Model {
        TunnelWidgetDisplay.model(for: entry.state, now: entry.date)
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryRectangular: rectangular
        case .accessoryInline:      inline
        case .systemMedium:         medium
        default:                    small
        }
    }

    @ViewBuilder
    private var background: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: Color.clear
        default: TunnelWidgetBackground(tone: model.tone)
        }
    }

    // MARK: Small — Home Screen, StandBy, CarPlay

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: Theme.Metrics.s1)
            Text(model.headline)
                .font(Theme.Typography.title.weight(.bold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .invalidatableContent()
            if let detail = model.detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            connectingBar
            Spacer(minLength: Theme.Metrics.s2)
            actionButton
        }
    }

    // MARK: Medium — Home Screen

    /// The state in its colour, large, with the route and the session's age;
    /// the round button beside it does what its words say.
    private var medium: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s4) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                header
                Spacer(minLength: 0)
                Text(model.headline)
                    .font(Theme.Typography.title.weight(.bold))
                    .foregroundStyle(model.tone == .on ? toneColor : Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .invalidatableContent()
                if let detail = model.detail {
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                connectingBar
                if let mode = model.mode {
                    Text(mode)
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            powerButton
        }
    }

    /// A large round power button: filled to start, quiet to stop.
    private var powerButton: some View {
        intentButton {
            VStack(spacing: Theme.Metrics.s1) {
                ZStack {
                    Circle()
                        .fill(isCallToAction ? AnyShapeStyle(Theme.Signal.actionGradient)
                                             : AnyShapeStyle(toneColor.opacity(0.18)))
                    Image(systemName: "power")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(isCallToAction ? Theme.Palette.onAccent : toneColor)
                }
                .frame(width: 72, height: 72)
                Text(TunnelWidgetDisplay.title(for: model.action))
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
    }

    // MARK: Inline — Lock Screen, above the clock

    private var inline: some View {
        Label("\(TunnelWidgetDisplay.brand): \(model.headline)", systemImage: glyph)
    }

    /// Glyph and name on the left; how long the session has been up (or which
    /// backend it will use) on the right.
    private var header: some View {
        HStack(spacing: Theme.Metrics.s1) {
            Image(systemName: glyph)
                .font(Theme.Typography.label)
                .foregroundStyle(toneColor)
            Text(TunnelWidgetDisplay.brand)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
            if let since = model.since {
                // A timer text takes all the width it is offered; bound it.
                Text(since, style: .timer)
                    .font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            } else if let mode = model.mode {
                Text(mode)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    /// While connecting: a bar the system fills over the usual time, and the
    /// seconds so far. Both move on their own between the app's updates — a
    /// widget cannot run an animation of its own.
    @ViewBuilder
    private var connectingBar: some View {
        if model.tone == .busy, let start = model.startedAt {
            HStack(spacing: Theme.Metrics.s2) {
                ProgressView(timerInterval: start...start.addingTimeInterval(TunnelWidgetDisplay.connectBudget),
                             countsDown: false,
                             label: { EmptyView() },
                             currentValueLabel: { EmptyView() })
                    .tint(Theme.Palette.amber)
                Text(start, style: .timer)
                    .font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 44, alignment: .trailing)
            }
            .padding(.top, Theme.Metrics.s1)
        }
    }

    private var actionButton: some View {
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
            .background(buttonFill, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Turning on is the call to action; turning off is the quieter choice.
    private var isCallToAction: Bool { model.action != .turnOff }

    private var buttonFill: AnyShapeStyle {
        isCallToAction ? AnyShapeStyle(Theme.Signal.actionGradient) : AnyShapeStyle(Theme.Palette.fill)
    }

    // MARK: Lock Screen

    private var circular: some View {
        intentButton {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: glyph)
                    .font(Theme.Typography.title)
            }
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }

    private var rectangular: some View {
        intentButton {
            HStack(spacing: Theme.Metrics.s2) {
                Image(systemName: glyph)
                    .font(Theme.Typography.title)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text(TunnelWidgetDisplay.brand)
                        .font(Theme.Typography.captionStrong)
                    Text(model.headline)
                        .font(Theme.Typography.bodyStrong)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .invalidatableContent()
                    Text(TunnelWidgetDisplay.title(for: model.action))
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Shared pieces

    /// The button for the model's action: an explicit value when the state is
    /// known, a toggle the app resolves when it is not.
    @ViewBuilder
    private func intentButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        switch model.action {
        case .turnOn:  Button(intent: SetTunnelRunningIntent(value: true), label: label)
        case .turnOff: Button(intent: SetTunnelRunningIntent(value: false), label: label)
        case .toggle:  Button(intent: ToggleTunnelIntent(), label: label)
        }
    }

    private var glyph: String {
        switch model.tone {
        case .on:      return "network"
        case .off:     return "network.slash"
        case .busy:    return "arrow.triangle.2.circlepath"
        case .problem: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var toneColor: Color {
        switch model.tone {
        case .on:      return Theme.Palette.green
        case .off:     return Theme.Palette.textSecondary
        case .busy:    return Theme.Palette.amber
        case .problem: return Theme.Palette.red
        case .unknown: return Theme.Palette.textTertiary
        }
    }
}

/// The card behind the Home Screen widgets. A live session glows in the
/// signal colours from two corners; a connection in progress warms one corner;
/// off, failed and unknown stay plain. CarPlay and StandBy remove it.
struct TunnelWidgetBackground: View {
    let tone: TunnelWidgetDisplay.Tone

    var body: some View {
        ZStack {
            Theme.Palette.card
            switch tone {
            case .on:
                RadialGradient(colors: [Theme.Palette.signalCyan.opacity(0.30), .clear],
                               center: .topTrailing, startRadius: 4, endRadius: 150)
                RadialGradient(colors: [Theme.Palette.signalViolet.opacity(0.24), .clear],
                               center: .bottomLeading, startRadius: 4, endRadius: 160)
            case .busy:
                RadialGradient(colors: [Theme.Palette.amber.opacity(0.18), .clear],
                               center: .topTrailing, startRadius: 4, endRadius: 140)
            case .off, .problem, .unknown:
                EmptyView()
            }
        }
    }
}

#if DEBUG
#Preview("olcOS — small", as: .systemSmall) {
    TunnelStatusWidget()
} timeline: {
    TunnelStatusEntry(date: Date(), state: TunnelWidgetState.preview(now: Date()))
    TunnelStatusEntry(date: Date(), state: TunnelWidgetState(phase: .off, service: "Yandex Telemost",
                                                             route: "VP8 · ams-1", mode: "proxy",
                                                             confirmedAt: Date()))
    TunnelStatusEntry(date: Date(), state: nil)
}
#endif
