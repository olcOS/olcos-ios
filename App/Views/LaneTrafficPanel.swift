import SwiftUI

// MARK: - LaneTrafficPanel
//
// While a session runs over several rooms — a whole server, or extra rooms of
// one service — what each room carries right now: its name, the download and
// the upload in the units a speed test uses, and a bar for its part of the
// download. Whether bonding adds up is then something to see rather than one
// number to trust. Every figure is the engine's own byte count over the last
// seconds; a room that carries nothing shows nothing.

struct LaneTrafficPanel: View {
    let lanes: [LaneReading]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Room for the widest reading ("↓ 888.8 Mbit/s"): a rate lives in a slot
    /// of this width, so a figure changing each second never moves its neighbours.
    @ScaledMetric(relativeTo: .body) private var rateSlot: CGFloat = 112

    private var shares: [Int: Double] { LaneReading.shares(lanes) }
    private var totalDown: Double { lanes.reduce(0) { $0 + max(0, $1.inBytesPerSecond) } }
    private var totalUp: Double { lanes.reduce(0) { $0 + max(0, $1.outBytesPerSecond) } }

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                Text(L10n.lanesPanelTitle.localized())
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(lanes) { lane in
                    row(lane)
                }
                Divider()
                total
            }
        }
    }

    private func row(_ lane: LaneReading) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
                Circle()
                    .fill(Self.color(lane.id))
                    .frame(width: 10, height: 10)
                Text(lane.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Metrics.s2)
                if lane.isUp {
                    rate("↓", lane.inBytesPerSecond, strong: true)
                } else {
                    Text(L10n.laneJoiningShort.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(minWidth: rateSlot, alignment: .trailing)
                }
            }
            // The second line is always there: a room joining the session
            // fills it in, it does not make the card taller.
            HStack(spacing: Theme.Metrics.s3) {
                bar(share: lane.isUp ? (shares[lane.id] ?? 0) : 0, color: Self.color(lane.id))
                if lane.isUp {
                    rate("↑", lane.outBytesPerSecond, strong: false)
                } else {
                    Text("↑ —")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(minWidth: rateSlot, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.laneRowA11y_fmt.formatted(lane.name,
                                                           ThroughputFormat.bits(lane.inBytesPerSecond),
                                                           ThroughputFormat.bits(lane.outBytesPerSecond)))
    }

    private var total: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
            Text(L10n.lanesPanelTotal.localized())
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Metrics.s2)
            rate("↓", totalDown, strong: true)
            rate("↑", totalUp, strong: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.laneRowA11y_fmt.formatted(L10n.lanesPanelTotal.localized(),
                                                           ThroughputFormat.bits(totalDown),
                                                           ThroughputFormat.bits(totalUp)))
    }

    private func rate(_ arrow: String, _ bytesPerSecond: Double, strong: Bool) -> some View {
        Text("\(arrow) \(ThroughputFormat.bits(bytesPerSecond))")
            .font(strong ? Theme.Typography.bodyStrong : Theme.Typography.body)
            .foregroundStyle(strong ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: rateSlot, alignment: .trailing)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: bytesPerSecond)
    }

    private func bar(share: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.fill)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, share)) * geo.size.width)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: share)
        .accessibilityHidden(true)
    }

    /// A lane keeps its colour for as long as it keeps its place.
    static func color(_ index: Int) -> Color {
        let palette = [Theme.Palette.signalCyan, Theme.Palette.signalViolet, Theme.Palette.green,
                       Theme.Palette.amber, Theme.Palette.signalMid, Theme.Palette.orange]
        return palette[index % palette.count]
    }
}
