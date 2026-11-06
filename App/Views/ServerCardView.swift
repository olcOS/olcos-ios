import SwiftUI

// MARK: - ServerCardView
//
// One VPS card. ServersView has hit the Swift type-checker's expression
// budget more than once, so the card is a small value-driven struct: every
// input is a plain value or a closure, explicitly typed, and every sub-view
// stays short.
//
// Reading order on the card is the order of the questions the owner asks,
// each answered once:
//   1 which server is this          → header (+ the machine, as one caption)
//   2 what is true right now        → the status headline; a re-read spins in
//                                     its glyph and changes nothing else
//   3 what runs on it, does it work → protocol rows, one per protocol
//   4 what do I do next             → one full-width action
//   5 what else can I do to it      → "Logs" / "Manage ›", one row of links
// Machine numbers (disk / RAM / uptime / ping) live on the Manage screen.

/// The primary action a card is allowed to offer: never one no evidence
/// justifies. A server nothing has ever read (`HostBase.unknown`) gets
/// **Check server**, never Install — `scripts/srv.sh` force-removes every
/// `olcrtc-server-*` container, so Install on a re-added VPS would destroy a
/// working deployment.
enum ServerPrimaryAction: Equatable {
    case busy, retry, check, start, stop, install

    var isBusy: Bool { self == .busy }

    var title: String {
        switch self {
        case .busy:    return L10n.vpsWorking.localized()
        case .retry:   return L10n.actionRetry.localized()
        case .check:   return L10n.vpsCheckServer.localized()
        case .start:   return L10n.actionStart.localized()
        case .stop:    return L10n.actionStop.localized()
        case .install: return L10n.actionInstall.localized()
        }
    }

    var systemImage: String? {
        switch self {
        case .busy:    return nil
        case .retry:   return "arrow.clockwise"
        case .check:   return "antenna.radiowaves.left.and.right"
        case .start:   return "play.fill"
        case .stop:    return "stop.fill"
        case .install: return "arrow.down.app"
        }
    }

    var role: OlcButton.Role {
        switch self {
        case .busy: return .secondary
        // #471 was: `.danger`. On a healthy server the LOUDEST element of the
        // whole card was the action the owner wants least often, painted in the
        // colour this app reserves for destruction ("Wipe all olcrtc data").
        // Stopping is undone by the same button one tap later; red stays on the
        // Manage screen, where the irreversible verbs live.
        case .stop: return .secondary
        default:    return .primary
        }
    }
}

// The machine's numbers (disk, memory, uptime) and its address live on the
// server's own management screen (`ServerMachineStats`,
// App/Views/ServerAdvancedView.swift); the card says what works, in words.

/// #471 was: the card's `quickRow` input. `ServerCardView` no longer draws a
/// quick-action button at all — "Container logs" is a text link in `manageRow`
/// — so nothing in the app builds one of these any more. The type stays because
/// `Review470Chunk6Tests.testQuickActionIdentityIsStableAcrossRebuilds` pins its
/// identity rule by name; delete both together.
///
/// #459: one visible quick action. It sat above the primary button — the verb
/// the owner reaches for constantly (Container logs), which used to cost a ⋯ tap
/// plus a scan of thirteen items. Value-driven and explicitly typed, like every
/// other input on this card, so the row costs the type-checker nothing.
/// #461 was: TWO of them, Check server first. `quickRow` still renders however
/// many it is handed, and only compacts them when there is more than one.
struct ServerQuickAction: Identifiable {
    // #470 was: `let id = UUID()` — a fresh identity on every parent render.
    // `ServersView.quickActions(host)` rebuilds this array on every body
    // evaluation (each provisioner line, each health tick, each tunnel
    // publish), so `ForEach(quickActions)` removed and re-inserted the button
    // every time — animated whenever the render was the one `.animation(value:
    // headline)` covers, and dropping a press held on it. The verb IS the
    // identity: same symbol + title ⇒ same button.
    var id: String { "\(systemImage)|\(title)" }
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// One already-resolved protocol row from outside the olcrtc container family
/// (Xray), drawn by `ServerCardView` after the call carriers.
struct ServerServiceRow: Identifiable {
    let id: String
    let view: ProtocolRowView
}

struct ServerCardView: View {
    /// Server label.
    let name: String
    /// The ONE headline (App/Models/HostDisplay.swift) — busy → op-failed →
    /// unreachable → never-checked → stopped → nothing-installed → measured health.
    let headline: HostHeadline
    /// Progress-bar fraction while an op runs; nil leaves the slot empty.
    let progress: Double?
    /// A background re-read is running while the card shows its last snapshot;
    /// the status glyph spins, nothing is added or resized.
    var isRefreshing: Bool = false
    let rows: [SSHRunner.CarrierInfo]
    /// A protocol-level op (add / remove / sibling start-stop) is in flight.
    let rowsBusy: Bool
    let listing: ServerProtocolListing // #490: never portray unread protocols as an empty successful scan.
    let canAddProtocol: Bool
    let actionsDisabled: Bool
    let primary: ServerPrimaryAction
    /// #471: there is a container on this server to read logs FROM. Before an
    /// install the card's whole offer is its primary CTA, so the Logs link is
    /// absent rather than opening an empty server — the same gate
    /// `ServersView.quickActions` used to apply to the button it replaces.
    /// #471 was: `quickActions: [ServerQuickAction]` — a full-width grey button
    /// stacked above the primary one, a THIRD action treatment on a card that
    /// has two.
    let canOpenLogs: Bool
    /// The safe, occasional action set for this server (5 items). Everything
    /// rare or destructive lives behind `onManage` (#459).
    let menuItems: [OlcMenuItem]
    let onPrimary: () -> Void
    let onAddProtocol: () -> Void
    /// #471: the container log — a text link beside "Manage ›" now, not a
    /// full-width button above the primary action.
    let onLogs: () -> Void
    /// #459: push the full server-management screen.
    let onManage: () -> Void
    /// Row factory — ServersView owns the resolution from a container to a record.
    let row: (SSHRunner.CarrierInfo) -> ProtocolRowView
    /// Protocols outside the olcrtc container family (Xray), already resolved
    /// into rows; drawn after the call carriers.
    var services: [ServerServiceRow] = []
    /// Rows drawn before the call carriers: the whole-server connection.
    var leading: [ServerServiceRow] = []

    // #490: no animation is mounted for idle server listings.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool {
        if case .busy = headline { return true }
        return false
    }

    // boc #490
    // #490 was: one enclosing OlcCard and five equally spaced blocks. Signal
    // floats identity above an evidence/protocol plate and keeps the main action
    // outside it, so the server, its readings and its controls have clear ranks.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            header
            evidencePlate
            actions
            manageRow
        }
        .tint(Theme.Signal.stroke)
        // Only an operation the person started animates the card (it starts and
        // ends with `isBusy`). The animation used to be keyed on `headline`,
        // whose cases carry an age measured at render time — so it was a new
        // value on EVERY render, and any size change a background check made
        // was animated as if the person had asked for it.
        .animation(reduceMotion ? nil : .easeOut(duration:
            ServerPresentationPolicy.transitionDuration(reduceMotion: reduceMotion)), value: isBusy)
    }

    private var evidencePlate: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                statusRegion
                if showsProtocols {
                    Divider().overlay(Theme.Palette.cardBorder)
                }
                protocolsSection
            }
        }
    }
    // eoc #490

    // MARK: 1 — identity

    private var header: some View {
        // #471: `8` / `1` → the grid. Same rhythm, through the tokens that name it.
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(name)
                    // #471 was: `.font(.headline)` — the card's SUBJECT, drawn
                    // one step below the type scale's subject step.
                    .font(Theme.Typography.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader) // #490: identify each server to VoiceOver.
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Spacer(minLength: Theme.Metrics.s2)
            OlcOverflowMenu(items: menuItems)
                .disabled(actionsDisabled)
        }
    }

    // MARK: 2 — what is true right now
    //
    // boc #471: the pill, and nothing else.
    //
    // #471 was: `verdict` — a VStack of `statusRegion` + `readStamp` +
    // `failureBanner`, i.e. the card's one claim ("Working"), how old that
    // claim is ("read 2 min ago") and a contradiction of it ("1 of 2 protocols
    // are not working") stacked 8pt apart in three different weights and two
    // different tones. The age and the count are inputs to
    // `HostHeadline.reduce` now (App/Models/HostDisplay.swift), which folds
    // both into the pill's own subtitle — "2 of 2 protocols verified 2 min
    // ago" — and flips the title to "Partly working" when they disagree. One
    // claim, dated once, counted once.
    //
    // #461's placement argument survives the deletion intact: how old a claim
    // is belongs BESIDE the claim, never at the bottom edge of the card. The
    // subtitle is as beside it as a line can get.
    // eoc #471

    /// #341/#335: fixed footprint — the pill always occupies the same slot and
    /// the bar below only fades its opacity, so starting an op never reflows the
    /// card or animates the pill from one anchor to another.
    // boc #490
    // #490 was: OlcStatusPill with a hidden progress slot and a fixed 58pt floor.
    // Use the same complete dated headline, without a pulsing status decoration.
    private var statusRegion: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            // A background re-read spins in the status glyph's own slot — a
            // note of its own would add a line while the card is read.
            ServerSignalStatus(tone: headline.tone, title: headline.title,
                               subtitle: headline.subtitle, problem: headline.problemLine,
                               isBusy: isBusy || isRefreshing)
            if let progress {
                ProgressView(value: progress)
                    .tint(Theme.Signal.stroke)
                    .accessibilityLabel(headline.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // eoc #490

    // MARK: 3 — the protocols (the content)

    /// #490: an olcrtc listing, any row, an Add action or another protocol.
    private var showsProtocols: Bool {
        listing != .absent || !rows.isEmpty || canAddProtocol || !services.isEmpty || !leading.isEmpty
    }

    @ViewBuilder
    private var protocolsSection: some View {
        // #490 was: only known rows or an available Add action showed the section.
        if showsProtocols {
            // #471 was: `Theme.Metrics.s2 + 2` between rows that each drew their
            // own inset plate. The plate is gone (ProtocolRowView), so the rows
            // separate the way an inset list does — one grid step and a
            // hairline — and a protocol looks the same object here as it does
            // on Connect.
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                protocolsHeader
                listingNote // #490: truthful loading/unread state, without a new clock.
                ForEach(leading) { service in
                    service.view
                    Divider().overlay(Theme.Palette.separator)
                }
                ForEach(rows) { info in protocolRow(info) }
                // Xray is not a call protocol: its rows sit under a heading of
                // their own, apart from the olcrtc ones above.
                if !services.isEmpty {
                    if !rows.isEmpty || !leading.isEmpty {
                        Divider().overlay(Theme.Palette.separator)
                    }
                    SignalSectionHeader(L10n.xrayCardSectionHeader.localized())
                }
                ForEach(services) { service in
                    if service.id != services.first?.id {
                        Divider().overlay(Theme.Palette.separator)
                    }
                    service.view
                }
            }
            .opacity(isBusy ? 0.45 : 1)
        }
    }

    // boc #490
    @ViewBuilder private var listingNote: some View {
        // A list already on screen is re-read quietly (the header spinner says
        // so); the note is for a card that has nothing to show yet.
        if listing == .loading, rows.isEmpty {
            Text(L10n.vpsWorking.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if listing == .unread {
            Text(L10n.vpsProcessUnread.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    // eoc #490

    /// #471: the hairline goes ABOVE every row but the first, so the header
    /// keeps its own gap and the list never ends on a dangling separator.
    @ViewBuilder
    private func protocolRow(_ info: SSHRunner.CarrierInfo) -> some View {
        if info.id != rows.first?.id { Divider().overlay(Theme.Palette.separator) }
        row(info)
    }

    /// #471: the design system's ONE section-header treatment, which until now
    /// had zero call sites while five views hand-rolled their own small-caps
    /// label. This one was caption2 / tertiary / no tracking; the component is
    /// captionStrong / secondary / 0.6 and uppercases through `textCase`, so the
    /// string is passed as written.
    /// #471 was: an HStack + `.uppercased()` + `.font(.caption2)`, with the
    /// busy spinner beside the title; it rides with the + button now, which is
    /// the only place `OlcSectionHeader` offers and the end of the row the
    /// spinner's work belongs to anyway.
    // boc #490
    // #490 was: uppercase OlcSectionHeader and a caption-sized plus action.
    private var protocolsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
                SignalSectionHeader(L10n.protocolsSectionHeader.localized())
                Spacer(minLength: Theme.Metrics.s2)
                protocolHeaderActions
            }
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                SignalSectionHeader(L10n.protocolsSectionHeader.localized())
                protocolHeaderActions
            }
        }
    }

    private var protocolHeaderActions: some View {
        HStack(spacing: Theme.Metrics.s2) {
            if rowsBusy || listing == .loading { ProgressView().controlSize(.small) } // #490
            if canAddProtocol { addProtocolButton }
        }
    }
    // eoc #490

    private var addProtocolButton: some View {
        OlcTapButton(action: onAddProtocol) {
            Label(L10n.addProtocolAction.localized(), systemImage: "plus.circle")
                .font(Theme.Typography.label) // #490 was: caption; actions need a readable label.
                .frame(minHeight: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .disabled(actionsDisabled)
    }

    // MARK: 4 — what do I do next (#471: ONE filled button)

    // #471 was: `metricsBlock` (`ServerMetricsGrid`, deleted with this block)
    // sat here, and `actions` wrapped `quickRow` — a full-width grey "Container
    // logs" — above the primary button. A healthy card therefore ended in THREE
    // action treatments: a grey full-width button, a RED full-width button, a
    // hairline, and a tiny grey caption link. Two now, and the loud one is the
    // only one the card is actually offering.

    private var actions: some View {
        // "Speed up: add a room" used to sit here as a second full-width button
        // and open the very same add-a-service-or-a-room sheet as the protocols
        // header's "+" — two controls, one action. The "+" is the one entry.
        OlcButton(primary.title, systemImage: primary.systemImage,
                  role: primary.role, isBusy: primary.isBusy,
                  fillWidth: true, action: onPrimary)
            .disabled(actionsDisabled && !primary.isBusy)
    }

    // MARK: 5 — everything else (#459)

    /// #459: the way to the rare and the destructive. Eleven ⋯ items became one
    /// row: a push whose `Form` can give every destructive verb a sentence
    /// saying what it destroys — which a `Menu` cannot render at all. That is
    /// why "Wipe all olcrtc data from server" used to sit in a scrolling list
    /// with nothing but its own name to warn you.
    /// #471 was: a `Divider` above a lone caption-weight "Manage server ›" at
    /// 32pt — the least visible thing on the card, under the most visible. The
    /// two links share one 44pt row at the control step now, which is where the
    /// frequent verb (Logs) lands after losing its button.
    private var manageRow: some View {
        // #490 was: a fixed HStack; long localized actions now wrap vertically.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Metrics.s2) {
                logsButton
                Spacer(minLength: Theme.Metrics.s2)
                manageButton
            }
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                logsButton
                manageButton
            }
        }
    }

    @ViewBuilder
    private var logsButton: some View {
        if canOpenLogs {
            linkButton(L10n.logsTitle.localized(), chevron: false, action: onLogs)
        }
    }

    private var manageButton: some View {
        linkButton(L10n.vpsManageServer.localized(), chevron: true, action: onManage)
    }

    /// #471: one treatment for both links — accent, control step, a 44pt tap
    /// target. `contentShape` is what makes the whole 44pt tappable rather than
    /// just the glyphs inside it.
    private func linkButton(_ title: String, chevron: Bool,
                            action: @escaping () -> Void) -> some View {
        OlcTapButton(action: action) {
            HStack(spacing: Theme.Metrics.s1) {
                Text(title)
                if chevron { Image(systemName: "chevron.right") }
            }
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Signal.stroke) // #490: shared Signal action accent.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionsDisabled)
    }
}

// #471 was: `ServerMetricsGrid` (#458) — PING / DISK / RAM / UP as a 2x2 grid
// of uppercase tracked labels over body-size monospaced semibold values, ~85
// lines of layout defending four readings against truncation inside a ~150pt
// column.
//
// #458's four rules are not regressed, they are made unnecessary: nothing has
// to fit a narrow column any more. Disk / RAM / uptime are ONE caption under
// the address (`machineCaption`), a single `Text` with
// `fixedSize(horizontal: false, vertical: true)` and no `minimumScaleFactor` —
// it wraps rather than shrinks, which is rule 3 restated for a line instead of
// a cell. All four readings also exist as full-width, label-left/value-right
// rows on the Manage screen (`ServerMachineStats`,
// App/Views/ServerAdvancedView.swift), where a Form row is the width of the
// phone and the value keeps its `lineLimit(1)` because a wrapped number is a
// lie. `ServersView.shortUsage` / `shortRAM` / `shortUptime` are untouched —
// `VPSStatFormattingTests` pins them by name, and rule 4 (a value that is <= 9
// characters by construction) is why the caption fits at all.
