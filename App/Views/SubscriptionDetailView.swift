import SwiftUI

// MARK: - SubscriptionDetailView
//
// One subscription, opened from the Connections tab: when it was last updated,
// its servers, and what the user may do with it — update it now, switch it off
// (it stays, but is not updated by itself and its servers are never picked
// automatically), rename it, or delete it together with every server it
// brought in. A row connects the way a row on the tab does.

struct SubscriptionDetailView: View {
    /// The key the list's bookkeeping is stored under.
    let source: String
    @ObservedObject var store: ConnectionStore
    @ObservedObject var tunnel: TunnelManager
    /// The tab's row menu, so a row here offers what a row there does.
    let menuItems: (ConnectionRecord) -> [OlcMenuItem]
    let onConnect: (ConnectionRecord) -> Void

    @ObservedObject private var health = HealthCoordinator.shared
    @StateObject private var search = BestServerSearch()
    @Environment(\.dismiss) private var dismiss

    /// Cached and re-sorted only when the list changes, so rows do not jump
    /// while checks run.
    @State private var servers: [ConnectionRecord] = []
    @State private var bestID: UUID?
    @State private var refreshing = false
    @State private var refreshFailed = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmDelete = false

    private var meta: ConnectionStore.SubscriptionMeta? { store.subscription(source) }
    private var title: String { SubscriptionText.title(source: source, meta: meta) }

    var body: some View {
        List {
            summarySection
            controlSection
            serversSection
            manageSection
        }
        .signalFormChrome()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshNow() }
        .onChange(of: store.connections, initial: true) { _, _ in recompute() }
        .onChange(of: search.isRunning) { _, running in if !running { recompute() } }
        .onChange(of: health.revision) { _, _ in recomputeBest() }
        // Deleted here, or its last server removed elsewhere: nothing to show.
        .onChange(of: meta == nil) { _, gone in if gone { dismiss() } }
        .alert(L10n.subRenameTitle.localized(), isPresented: $renaming) {
            TextField(L10n.subRenamePlaceholder.localized(), text: $draftName)
            Button(L10n.cancel.localized(), role: .cancel) {}
            Button(L10n.save.localized()) { store.renameSubscription(source, to: draftName) }
        } message: {
            Text(L10n.subRenameHint.localized())
        }
        .confirmationDialog(L10n.subDeleteTitle.localized(), isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button(L10n.subDeleteAction.localized(), role: .destructive) { delete() }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: {
            Text(L10n.subDeleteMessage_fmt.formatted(servers.count))
        }
    }

    // MARK: Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                line(SubscriptionText.counts(servers: servers.count, working: counts.working,
                                             checked: counts.checked))
                if let meta {
                    line(SubscriptionText.updated(meta.lastRefresh))
                    if let interval = meta.refreshInterval.flatMap({ SubscriptionText.interval($0) }) {
                        line(L10n.subAutoRefresh_fmt.formatted(interval))
                    }
                    if let used = meta.used, !used.isEmpty {
                        line(L10n.listSubscriptionUsed_fmt.formatted(used))
                    }
                    if let available = meta.available, !available.isEmpty {
                        line(L10n.listSubscriptionAvailable_fmt.formatted(available))
                    }
                }
                if let host = URL(string: ConnectionStore.canonicalSource(source))?.host {
                    line(L10n.subFrom_fmt.formatted(host))
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
        }
        .signalFormRows()
    }

    private var controlSection: some View {
        Section {
            Toggle(isOn: Binding(get: { meta?.isEnabled ?? true },
                                 set: { store.setSubscription(source, enabled: $0) })) {
                Text(L10n.subEnabled.localized())
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            Button {
                Task { await refreshNow() }
            } label: {
                HStack(spacing: Theme.Metrics.s3) {
                    if refreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Theme.Palette.accentTint)
                            .accessibilityHidden(true)
                    }
                    Text(refreshing ? L10n.subRefreshing.localized() : L10n.subRefreshNow.localized())
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.accentTint)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
            if refreshFailed {
                FormNote(text: L10n.subRefreshFailed.localized(), tone: .warn)
            }
        } footer: {
            Text(L10n.subEnabledFooter.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .signalFormRows()
    }

    private var serversSection: some View {
        Section {
            if servers.isEmpty {
                line(L10n.subNoServers.localized())
            } else if servers.count > 1 {
                BestServerSearchRow(search: search, records: servers, tunnel: tunnel,
                                    health: health) { onConnect($0) }
            }
            ForEach(servers) { record in
                ConnectionListRow(title: ConnectionNaming.listTitle(record),
                                  subtitle: subtitle(record),
                                  display: health.settledDisplay(for: record.id),
                                  isSelected: record.id == selectedID,
                                  isLive: tunnel.state.isConnected && tunnel.connectedRecord?.id == record.id,
                                  isBest: record.id == bestID,
                                  isRefreshing: health.isChecking(record.id),
                                  menuItems: menuItems(record),
                                  onTap: { onConnect(record) },
                                  onVerify: { verify(record) })
            }
        } header: {
            SignalSectionHeader(L10n.subServersHeader.localized(), systemImage: "server.rack")
        } footer: {
            if meta?.isEnabled == false {
                Text(L10n.subOffNote.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .signalFormRows()
    }

    private var manageSection: some View {
        Section {
            Button {
                draftName = meta?.customName ?? ""
                renaming = true
            } label: {
                Label(L10n.subRenameAction.localized(), systemImage: "pencil")
                    .font(Theme.Typography.bodyStrong)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label(L10n.subDeleteAction.localized(), systemImage: "trash")
                    .font(Theme.Typography.bodyStrong)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
        }
        .signalFormRows()
    }

    /// A list is mostly direct servers: saying so on every row is noise, so
    /// only a call protocol's row says where it goes.
    private func subtitle(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .xray:   return ""
        case .olcrtc: return ConnectionNaming.listSubtitle(record)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: State

    private var counts: (working: Int, checked: Int) {
        ConnectionSections.counts(servers) { health.settledDisplay(for: $0) }
    }

    /// The connection Connect would use: the live one, else the last chosen.
    private var selectedID: UUID? {
        tunnel.state.isConnected ? tunnel.connectedRecord?.id : (tunnel.engagedRecord ?? store.primary)?.id
    }

    private func recompute() {
        servers = ConnectionSections.byHealth(store.records(ofSubscription: source)) { health.settledDisplay(for: $0) }
        recomputeBest()
    }

    private func recomputeBest() {
        let best = health.bestChoice(among: servers.map(\.id))
        if best != bestID { bestID = best }
    }

    // MARK: Actions

    private func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        refreshFailed = false
        let refreshed = await store.refreshSource(source)
        refreshing = false
        refreshFailed = !refreshed
        // Its call protocols and the servers that worked last time, not every
        // one of a list of hundreds; the search for the fastest does the rest.
        if refreshed {
            health.verifyAll(health.automaticSweepCandidates(store.records(ofSubscription: source), keep: []),
                             using: tunnel)
        }
    }

    private func verify(_ record: ConnectionRecord) {
        Task { await health.verify(record, using: tunnel, force: true) }
    }

    /// The page closes by itself once the subscription is gone.
    private func delete() {
        let mine = Set(store.records(ofSubscription: source).map(\.id))
        if let live = tunnel.connectedRecord?.id, mine.contains(live) { tunnel.disconnect() }
        store.removeSubscription(source)
    }
}
