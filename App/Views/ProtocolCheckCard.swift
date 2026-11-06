import SwiftUI

// MARK: - ProtocolCheckCard
//
// The connection check's answer to "which protocol is fastest, and does
// bonding add up": one row per room of the live session and a last row for
// all of them together. A row being measured draws its speed as it comes in;
// a finished one reads its download, round trip and exit. "Check all" goes
// through every row in turn; a row's own button checks just that one.

struct ProtocolCheckCard: View {
    @ObservedObject var check: ProtocolSpeedCheck
    let onRunAll: () -> Void
    let onRunOne: (Int) -> Void

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                Text(L10n.protoCheckTitle.localized())
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(L10n.protoCheckLead.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(check.rows) { row in
                    Divider()
                    rowView(row)
                }
                if let gain = ProtocolSpeedCheck.gain(check.rows) {
                    Divider()
                    Text(L10n.protoCheckGain_fmt.formatted(ThroughputFormat.number(gain, fractionDigits: 1,
                                                                                   locale: .current)))
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(gain > 1.1 ? Theme.Palette.green : Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OlcButton(runAllTitle,
                          systemImage: check.isRunning ? "stop.circle" : "speedometer",
                          role: check.isRunning ? .secondary : .primary, fillWidth: true) {
                    if check.isRunning { check.cancel() } else { onRunAll() }
                }
            }
        }
    }

    /// "Check all", or "Check again" once there are results, or "Stop".
    private var runAllTitle: String {
        if check.isRunning { return L10n.protoCheckStop.localized() }
        let measured = check.rows.contains { $0.phase == .done || $0.phase == .failed }
        return (measured ? L10n.protoCheckRunAgain : L10n.protoCheckRunAll).localized()
    }

    private func rowView(_ row: ProtocolSpeedCheck.Row) -> some View {
        let isTogether = row.id == ProtocolSpeedCheck.allTogether
        let isFastest = !isTogether && ProtocolSpeedCheck.fastestLane(check.rows)?.id == row.id
        return VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
                if !isTogether {
                    Circle()
                        .fill(LaneTrafficPanel.color(row.id))
                        .frame(width: 10, height: 10)
                }
                Text(isTogether ? L10n.protoCheckAllTogether.localized() : row.name)
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if isFastest {
                    Text(L10n.protoCheckFastest.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.green)
                        .padding(.horizontal, Theme.Metrics.s2)
                        .padding(.vertical, 2)
                        .background(Theme.Palette.fill, in: Capsule())
                        .fixedSize()
                }
                Spacer(minLength: Theme.Metrics.s2)
                trailing(row)
            }
            switch row.phase {
            case .measuring:
                SpeedSparkline(samples: row.samples, color: isTogether ? Theme.Palette.accentTint
                                                                        : LaneTrafficPanel.color(row.id))
                    .frame(height: 36)
            case .done:
                Text(resultLine(row))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                Text(L10n.protoCheckFailed.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.orange)
            case .reconnecting:
                Text(L10n.protoCheckReconnecting.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .waiting:
                EmptyView()
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ row: ProtocolSpeedCheck.Row) -> some View {
        switch row.phase {
        case .measuring:
            Text(row.samples.last.map { ThroughputFormat.bits($0) } ?? L10n.protoCheckMeasuring.localized())
                .font(Theme.Typography.bodyStrong)
                .monospacedDigit()
                .contentTransition(.numericText())
        case .waiting:
            Text(L10n.protoCheckWaiting.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .done:
            HStack(spacing: Theme.Metrics.s2) {
                Text(ThroughputFormat.bits(row.bytesPerSecond ?? 0))
                    .font(Theme.Typography.bodyStrong)
                    .monospacedDigit()
                // A measured row is checked again on its own, as often as wanted.
                if !check.isRunning {
                    Button { onRunOne(row.id) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.protoCheckRunOne.localized())
                }
            }
        case .idle, .failed, .reconnecting:
            if !check.isRunning {
                Button(L10n.protoCheckRunOne.localized()) { onRunOne(row.id) }
                    .font(Theme.Typography.bodyStrong)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func resultLine(_ row: ProtocolSpeedCheck.Row) -> String {
        var parts: [String] = []
        if let ms = row.pingMs { parts.append(L10n.protoCheckPing_fmt.formatted(ms)) }
        if let exit = row.exit { parts.append(exit) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - SpeedSparkline

/// The speed of a running download, newest on the right, scaled to its peak.
struct SpeedSparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = Array(samples.suffix(40))
            let peak = max(points.max() ?? 0, 1)
            let step = geo.size.width / CGFloat(max(points.count - 1, 1))
            Path { path in
                for (i, value) in points.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step,
                                        y: geo.size.height * (1 - CGFloat(value / peak)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .animation(.linear(duration: 0.25), value: samples.count)
        }
        .accessibilityHidden(true)
    }
}
