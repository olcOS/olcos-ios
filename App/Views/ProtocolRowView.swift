import SwiftUI

// MARK: - ProtocolRowView
//
// One compact row per protocol on a server card. Every input is a plain value
// or a closure and every parameter is explicitly typed, so the row costs the
// ServersView type-checker nothing to resolve.
//
// The row answers "what is this protocol, does it work, and how do I connect":
//  • identity — "carrier · transport", one line, never duplicated in the chip;
//  • state — one short word under the identity (live / not running on the
//    server), omitted when nothing is exceptional;
//  • evidence — the ONE `OlcHealthChip` (App/UI/HealthChip.swift), the same
//    glow-dot status the Connections rows draw, and the only source of colour;
//  • the row itself opens the protocol's page (`onOpen`), or connects when the
//    caller gives no page; the overflow menu holds the quick actions.
// Nothing here is carried by colour alone: the live protocol is NAMED, and the
// leading spine is a verdict mark (live and verified), not decoration.

struct ProtocolRowView: View {
    /// Service display name ("Yandex Telemost"), from `CarrierTransportMatrix.carrierLabel`.
    let title: String
    /// Transport display label ("VP8"), from `CarrierTransportMatrix.transportLabel`.
    let transport: String
    /// The live tunnel currently runs through this protocol.
    let isLive: Bool
    /// The server-side process for this protocol is up (a real reading, not a guess).
    let isRunningOnServer: Bool
    /// Measured evidence — the ONLY source of colour (App/Models/NodeHealth.swift).
    let health: HealthDisplay
    /// True while an SSH op holds the lane.
    let menuDisabled: Bool
    /// The complete action set for this protocol — ONE menu, no rival controls.
    let menuItems: [OlcMenuItem]
    /// Verified one-line descriptions of the carrier and transport
    /// (`ProtocolDescriptions.lines`); shown on demand from the menu.
    var detailLines: [String] = []
    /// `BestChoice`'s pick among this server's protocols.
    var isBest: Bool = false
    /// Rooms the server sits in for this protocol (more than one = lanes).
    var roomCount: Int = 1
    /// One more short fact for the state line ("Rooms: 3 · together").
    var stateNote: String? = nil
    /// The rooms of a whole-server row that did not answer ("Not responding:
    /// Telemost"), in the warning colour under the state line.
    var problemNote: String? = nil
    /// The verdict is being re-measured: the last one stays in the chip.
    var isRefreshing: Bool = false
    /// The container does not run: the row says «Stopped» in grey instead of
    /// a verdict, which would be about a protocol that is not there now. A
    /// check the user asks for still shows its spinner and its result.
    var isStopped: Bool = false
    /// Re-run the end-to-end probe for THIS protocol.
    let onVerify: () -> Void
    /// Connect through this protocol (the whole row, when there is no page).
    let onConnect: () -> Void
    /// Opens the protocol's own page: the whole row becomes that control.
    var onOpen: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            connectRow
            if showsDetail, !detailLines.isEmpty { detail }
        }
        .padding(.vertical, Theme.Metrics.s2)
        // A verdict from a background check lands in place, unanimated.
        .transaction { $0.animation = nil }
    }

    /// The tappable body: identity + state on the left, evidence chip on the
    /// right, overflow at the trailing edge. A live row is not re-connectable,
    /// and it is not a disabled button either: that would grey out the one
    /// row that matters most and switch off its chip's re-verify tap.
    private var connectRow: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s2) {
            if let onOpen {
                Button {
                    Haptics.tap()
                    onOpen()
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint(L10n.protocolOpenAction.localized())
            } else if isLive {
                rowContent
            } else {
                Button {
                    guard !menuDisabled else { return }
                    Haptics.impact()
                    onConnect()
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .disabled(menuDisabled)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint(L10n.actionConnect.localized())
            }
            OlcOverflowMenu(items: allMenuItems)
                .disabled(menuDisabled)
        }
        .overlay(alignment: .leading) { spine }
    }

    private var rowContent: some View {
        layout
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var layout: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            // One line when the title and the verdict both fit whole; on a
            // narrow screen the verdict moves under the title instead of
            // either being cut ("14…", "No answer in the ro…").
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Metrics.s3) {
                    labels
                    Spacer(minLength: Theme.Metrics.s2)
                    verdict(inline: false)
                }
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            labels
            verdict(inline: true)
        }
    }

    private var showsStopped: Bool { isStopped && !isLive && !isRefreshing }

    @ViewBuilder
    private func verdict(inline: Bool) -> some View {
        if showsStopped {
            Text(L10n.protocolStopped.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .padding(.vertical, Theme.Metrics.s1)
        } else {
            OlcHealthChip(display: health, onTap: onVerify, inline: inline, isRefreshing: isRefreshing)
        }
    }

    /// Both lines wrap instead of ending in an ellipsis: a protocol's name and
    /// its state are read whole, whatever the width and the text size.
    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(headline)
                .font(isLive ? Theme.Typography.bodyStrong : Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let state = stateText {
                Text(state)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problemNote {
                Text(problemNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(OlcStatusTone.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isBest { OlcBestTag() }
        }
    }

    /// The one exceptional fact about this row, or nil when there is none.
    private var stateText: String? {
        var parts: [String] = []
        if isLive {
            parts.append(L10n.protocolLiveBadge.localized())
        } else if !isRunningOnServer, !showsStopped {
            parts.append(L10n.protocolStoppedNote.localized())
        }
        if roomCount > 1 { parts.append(L10n.lanesRoomCount_fmt.formatted(roomCount)) }
        if let stateNote, !stateNote.isEmpty { parts.append(stateNote) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            ForEach(detailLines, id: \.self) { line in
                Text(line)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Theme.Metrics.s1)
    }

    /// Menu = the caller's actions plus "About this protocol" when there is a
    /// description to show.
    private var allMenuItems: [OlcMenuItem] {
        guard !detailLines.isEmpty else { return menuItems }
        let about = OlcMenuItem.action(
            showsDetail ? L10n.protocolAboutHide.localized() : L10n.protocolAboutAction.localized(),
            systemImage: "info.circle") { showsDetail.toggle() }
        return menuItems + [.divider, about]
    }

    /// Verdict mark: live + verified → stroke; live but unproven → neutral;
    /// anything else → nothing, because an unproven row must draw nothing.
    private var spine: some View {
        Capsule(style: .continuous)
            .fill(spineStyle)
            .frame(width: 3)
            .frame(height: Theme.Metrics.s6)
            .offset(x: -Theme.Metrics.s2)
            .accessibilityHidden(true)
    }

    private var spineStyle: AnyShapeStyle {
        if isLive && health.isVerified { return AnyShapeStyle(Theme.Signal.stroke) }
        if isLive { return AnyShapeStyle(Theme.Palette.textTertiary) }
        return AnyShapeStyle(Color.clear)
    }

    /// "Яндекс Телемост", or "title · detail" when the caller gives a detail.
    private var headline: String {
        transport.isEmpty ? title : "\(title) · \(transport)"
    }

    private var accessibilityTitle: String {
        var parts = [headline]
        if showsStopped { parts.append(L10n.protocolStopped.localized()) }
        if let state = stateText { parts.append(state) }
        if let problemNote { parts.append(problemNote) }
        if isBest { parts.append(L10n.healthBestChoice.localized()) }
        return parts.joined(separator: ". ")
    }
}

#if DEBUG
#Preview("Protocol row — Dark") {
    VStack(spacing: Theme.Metrics.s3) {
        ProtocolRowView(title: "Yandex Telemost", transport: "VP8",
                        isLive: true, isRunningOnServer: true,
                        health: .verified(ms: 48, age: 120),
                        menuDisabled: false, menuItems: [],
                        detailLines: ProtocolDescriptions.lines(carrier: "telemost", transport: "vp8channel"),
                        onVerify: {}, onConnect: {})
        Divider().overlay(Theme.Palette.separator)
        ProtocolRowView(title: "Jitsi", transport: "DataChannel",
                        isLive: false, isRunningOnServer: false,
                        health: .never,
                        menuDisabled: false, menuItems: [], onVerify: {}, onConnect: {})
        Divider().overlay(Theme.Palette.separator)
        ProtocolRowView(title: "VK Calls", transport: "VP8",
                        isLive: false, isRunningOnServer: true,
                        health: .broken(.keyMismatch, age: 300),
                        menuDisabled: false, menuItems: [], onVerify: {}, onConnect: {})
    }
    .padding()
    .background(Theme.Palette.bg)
    .preferredColorScheme(.dark)
}
#endif
