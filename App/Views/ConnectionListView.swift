import SwiftUI

// MARK: - ConnectionListView — the Connections tab
//
// Every connection the app knows: the user's own servers, each as the one
// connection through all of its rooms plus its own page (rooms, speed-up,
// logs, updates) one push away; then the call links the user added by hand;
// then one row to "Subscriptions and Xray" — the subscriptions (each opening
// to the servers it brought in), the ready-made lists and the direct Xray
// servers, kept a page away from the olcrtc ones.
// A tap connects through a row and goes back to Home, where the state is
// shown. The «+» brings in more: a link, a QR code, a file, a subscription, or
// the user's own server.
//
// Rows carry no codec names and no ages: the name, which server, and one word
// for whether it works; a subscription says when it was updated as a clock
// time. Checks run when the app opens and on every connect; a pull checks
// everything again.

struct ConnectionListView: View {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var serverStore: ServerHostStore
    var inviteSync: InviteSync? = nil
    var bundleSync: BundleSync? = nil
    /// Set by the first-run screen and the «+» menu: open the add-server wizard.
    @Binding var addServerPending: Bool
    /// Set by Home's stale-server notice: open My servers.
    var myServersPending: Binding<Bool> = .constant(false)
    /// Told the core commit each server screen reads.
    var coreWatch: CoreVersionWatch? = nil
    let onImportText: (String) -> Void
    var onPasteImport: ((OlcrtcSubscription.ImportInput) -> Void)? = nil
    /// A row started a connection: show it on Home.
    var onConnectStarted: () -> Void = {}

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var health = HealthCoordinator.shared

    private enum Route: Hashable {
        /// Every server, and the add-server wizard.
        case myServers
        /// One server's own page.
        case server(UUID)
        /// One subscription, by the key its bookkeeping is stored under.
        case subscription(String)
        /// Subscriptions, the ready-made lists and the direct (Xray) servers.
        case extras
    }
    @State private var path: [Route] = []

    private enum Sheet: Identifiable {
        case add
        case edit(ConnectionRecord)
        case qr(ConnectionRecord)
        case share(ConnectionRecord)
        case scanner
        case link
        case curated

        var id: String {
            switch self {
            case .add:           return "add"
            case .edit(let c):   return "edit-\(c.id.uuidString)"
            case .qr(let c):     return "qr-\(c.id.uuidString)"
            case .share(let c):  return "share-\(c.id.uuidString)"
            case .scanner:       return "scanner"
            case .link:          return "link"
            case .curated:       return "curated"
            }
        }
    }
    @State private var sheet: Sheet?
    /// Text a sheet brought in, imported once the sheet has gone.
    @State private var pendingImport: String?
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var importError: String?

    /// Cached: `body` must not derive these (the list redraws while checks run).
    @State private var sections = ConnectionSections()
    @State private var bestID: UUID?
    /// Per subscription: how many of its servers work, and were checked.
    @State private var subscriptionCounts: [String: SubscriptionCounts] = [:]
    /// Subscriptions whose list is being fetched from their row's button, and
    /// those whose last such fetch failed.
    @State private var refreshingSources: Set<String> = []
    @State private var failedSources: Set<String> = []
    @StateObject private var search = BestServerSearch()

    private struct SubscriptionCounts: Equatable {
        var working = 0
        var checked = 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            importWiring(listWiring(listChrome(list)))
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .myServers:
                        myServers
                    case .server(let id):
                        serverPage(id)
                    case .subscription(let source):
                        SubscriptionDetailView(source: source, store: store, tunnel: tunnel,
                                               menuItems: menuItems, onConnect: connect)
                    case .extras:
                        extrasPage
                    }
                }
        }
        .onChange(of: addServerPending, initial: true) { _, pending in
            if pending, path != [.myServers] { path = [.myServers] }
        }
        .onChange(of: myServersPending.wrappedValue, initial: true) { _, pending in
            guard pending else { return }
            myServersPending.wrappedValue = false
            if path != [.myServers] { path = [.myServers] }
        }
    }

    private func listChrome(_ content: some View) -> some View {
        content
            .signalFormChrome()
            .refreshable { await refreshEverything() }
            .navigationTitle(L10n.tabServers.localized())
            .toolbar { ToolbarItem(placement: .primaryAction) { addMenu } }
    }

    private func listWiring(_ content: some View) -> some View {
        content
            .onChange(of: store.connections, initial: true) { _, _ in recompute() }
            .onChange(of: store.subscriptionMeta) { _, _ in recompute() }
            .onChange(of: serverStore.hosts) { _, _ in recompute() }
            .onChange(of: search.isRunning) { _, running in if !running { recompute() } }
            .onChange(of: health.revision) { _, _ in
                recomputeBest()
                recomputeCounts()
            }
            .sheet(item: $sheet, onDismiss: importPending) { sheetContent($0) }
    }

    /// The file picker and its error, off the other chains for the type-checker.
    private func importWiring(_ content: some View) -> some View {
        content
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: ImportFile.contentTypes) { result in
                switch ImportFile.read(result) {
                case .text(let text):       onImportText(text)
                case .failure(let message): importError = message
                }
            }
            .photoQRImport(isPresented: $showPhotoPicker,
                           onResult: { onImportText($0) },
                           onFailure: { importError = $0 })
            .alert(L10n.okPrompt.localized(),
                   isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button(L10n.ok.localized()) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    private var addMenu: some View {
        AddSourcesMenu(onPaste: { onImportText(UIPasteboard.general.string ?? "") },
                       onScan: { sheet = .scanner },
                       onPhoto: { showPhotoPicker = true },
                       onFile: { showFilePicker = true },
                       onLink: { sheet = .link },
                       onCurated: { sheet = .curated },
                       onManual: { sheet = .add },
                       onOwnServer: { addServerPending = true })
    }

    // MARK: The list

    private var list: some View {
        List {
            if store.connections.isEmpty {
                emptySection
            }
            ForEach(sections.own) { server in
                ownServerSection(server)
            }
            myServersSection
            if !sections.calls.isEmpty {
                ownLinksSection
            }
            extrasSection
            if store.connections.count > 1 {
                switchingSection
            }
        }
    }

    /// One row per subscription, opening to its servers; under them, the two
    /// ways to add one, always in sight.
    private var subscriptionsSection: some View {
        Section {
            ForEach(sections.subscriptions) { subscription in
                NavigationLink(value: Route.subscription(subscription.source)) {
                    subscriptionRow(subscription)
                }
            }
            addRow(L10n.listAddOwnSubscription.localized(), systemImage: "plus.circle.fill") { sheet = .link }
            addRow(L10n.addMenuCurated.localized(), systemImage: "list.bullet.rectangle") { sheet = .curated }
        } header: {
            SignalSectionHeader(L10n.listSectionSubscriptions.localized(), systemImage: "arrow.down.circle")
        }
        .signalFormRows()
    }

    private func subscriptionRow(_ subscription: ConnectionSections.Subscription) -> some View {
        let meta = store.subscription(subscription.source)
        let counts = subscriptionCounts[subscription.source] ?? SubscriptionCounts()
        return SubscriptionSourceRow(
            title: SubscriptionText.title(source: subscription.source, meta: meta),
            counts: SubscriptionText.counts(servers: subscription.records.count,
                                            working: counts.working, checked: counts.checked),
            updated: meta.map { SubscriptionText.updated($0.lastRefresh) },
            isEnabled: meta?.isEnabled ?? true,
            isRefreshing: refreshingSources.contains(subscription.source),
            refreshFailed: failedSources.contains(subscription.source),
            onRefresh: { refresh(subscription.source) })
    }

    /// Fetches one list now, from its row.
    private func refresh(_ source: String) {
        guard !refreshingSources.contains(source) else { return }
        refreshingSources.insert(source)
        failedSources.remove(source)
        Task {
            // Another pass running (launch, a pull) takes this list along: only
            // a fetch of our own that brought nothing is a failure to show.
            let busy = store.refreshing
            if !(await store.refreshSource(source)), !busy { failedSources.insert(source) }
            refreshingSources.remove(source)
        }
    }

    private func addRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        OlcTapButton(action: action) {
            HStack(spacing: Theme.Metrics.s3) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.accentTint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.accentTint)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptySection: some View {
        Section {
            Text(L10n.listEmpty.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Theme.Metrics.s2)
        }
        .signalFormRows()
    }

    /// Switching to a working connection when the current one stops.
    private var switchingSection: some View {
        Section {
            Toggle(isOn: $settings.autoFailover) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(L10n.listAutoSwitch.localized())
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.listAutoSwitchDetail.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
            // A switch gives the selection tick when the person flips it.
            .onChange(of: settings.autoFailover) { _, _ in Haptics.tap() }
        }
        .signalFormRows()
    }

    /// The call links the user added by hand. Each row's second line says how
    /// it travels.
    private var ownLinksSection: some View {
        Section {
            ForEach(sections.calls) { row($0) }
        } header: {
            SignalSectionHeader(L10n.listSectionOwnLinks.localized(), systemImage: "link")
        } footer: {
            Text(L10n.listSectionOwnLinksFooter.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .signalFormRows()
    }

    /// The one row to the subscriptions, the ready-made lists and the direct
    /// (Xray) servers, with how many there are.
    private var extrasSection: some View {
        Section {
            NavigationLink(value: Route.extras) {
                SignalSettingsLabel(L10n.listExtrasTitle.localized(),
                                    subtitle: extrasSummary,
                                    systemImage: "tray.full")
            }
        }
        .signalFormRows()
    }

    private var extrasSummary: String {
        let lists = sections.subscriptions.count
        let direct = sections.direct.count
        guard lists > 0 || direct > 0 else { return L10n.listExtrasEmpty.localized() }
        return L10n.listExtrasSummary_fmt.formatted(lists, direct)
    }

    /// Subscriptions with the two ways to add one, then the direct (Xray)
    /// servers with the search for a working one when there are several — a
    /// list of free servers is mostly dead ones.
    private var extrasPage: some View {
        List {
            subscriptionsSection
            if !sections.direct.isEmpty {
                directSection
            }
        }
        .signalFormChrome()
        .refreshable { await refreshEverything() }
        .navigationTitle(L10n.listExtrasTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var directSection: some View {
        Section {
            if sections.direct.count > 1 {
                BestServerSearchRow(search: search, records: sections.direct, tunnel: tunnel,
                                    health: health) { connect($0) }
            }
            ForEach(sections.direct) { row($0) }
        } header: {
            SignalSectionHeader(L10n.listSectionXray.localized(), systemImage: "bolt.horizontal")
        }
        .signalFormRows()
    }

    /// One server under its own name: the connection through all of it, then
    /// its own page — rooms, speed-up, logs, updates — one tap away.
    private func ownServerSection(_ server: ConnectionSections.OwnServer) -> some View {
        Section {
            if server.records.isEmpty {
                Text(L10n.listOwnServerEmpty.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(server.records) { row($0, subtitle: ConnectionNaming.ownServerSubtitle($0)) }
            NavigationLink(value: Route.server(server.id)) {
                SignalSettingsLabel(L10n.listOpenServer.localized(),
                                    subtitle: L10n.listOpenServerDetail.localized(),
                                    systemImage: "slider.horizontal.3")
            }
        } header: {
            SignalSectionHeader(L10n.listOwnServerHeader_fmt.formatted(server.label), systemImage: "server.rack")
        }
        .signalFormRows()
    }

    /// No server of one's own yet: the way to put olcOS on one.
    @ViewBuilder
    private var myServersSection: some View {
        if serverStore.hosts.isEmpty {
            Section {
                addRow(L10n.listAddOwnServer.localized(), systemImage: "server.rack") { addServerPending = true }
            } footer: {
                Text(L10n.listMyServersNone.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .signalFormRows()
        }
    }

    /// `subtitle` nil: the connection's usual second line.
    private func row(_ record: ConnectionRecord, subtitle: String? = nil) -> some View {
        ConnectionListRow(title: ConnectionNaming.listTitle(record),
                          subtitle: subtitle ?? ConnectionNaming.listSubtitle(record),
                          display: shownDisplay(record),
                          isSelected: record.id == selectedID,
                          isLive: tunnel.state.isConnected && tunnel.connectedRecord?.id == record.id,
                          isBest: record.id == bestID,
                          isRefreshing: health.isChecking(record.id),
                          problem: failedRooms(record),
                          menuItems: menuItems(record),
                          onTap: { connect(record) },
                          onVerify: { verify(record) })
            .swipeActions(edge: .trailing) {
                if !record.isBundle {
                    Button(role: .destructive) { remove(record) } label: {
                        Label(L10n.connectRowRemove.localized(), systemImage: "minus.circle")
                    }
                }
            }
    }

    /// A whole-server connection stands on the rooms it joins as well as on its
    /// own check; every other connection on its own verdict.
    private func shownDisplay(_ record: ConnectionRecord) -> HealthDisplay {
        record.isBundle ? health.bundleDisplay(for: record, among: store.connections)
                        : health.settledDisplay(for: record.id)
    }

    /// The rooms of a whole-server connection whose last check failed, and
    /// those whose container is stopped.
    private func failedRooms(_ record: ConnectionRecord) -> String? {
        guard record.isBundle else { return nil }
        let marks = health.bundleMarks(for: record, among: store.connections)
        return ProtocolsTally.make(marks, rows: marks.count).roomsNote
    }

    /// The connection a tap on Connect would use: the live one, else the last chosen.
    private var selectedID: UUID? {
        tunnel.state.isConnected ? tunnel.connectedRecord?.id : (tunnel.engagedRecord ?? store.primary)?.id
    }

    // MARK: My servers

    private var myServers: some View {
        ServersView(serverStore: serverStore, connections: store, tunnel: tunnel,
                    inviteSync: inviteSync, bundleSync: bundleSync,
                    addServerPending: $addServerPending, embedded: true, coreWatch: coreWatch,
                    onConnectStarted: backToMainScreen)
    }

    private func serverPage(_ id: UUID) -> some View {
        ServersView(serverStore: serverStore, connections: store, tunnel: tunnel,
                    inviteSync: inviteSync, bundleSync: bundleSync,
                    embedded: true, focusHostID: id, coreWatch: coreWatch,
                    onConnectStarted: backToMainScreen)
    }

    /// A protocol page connected: this tab goes back to its list, so it is
    /// there when the person returns, and the main screen shows the state —
    /// the same landing as a tap on a row.
    private func backToMainScreen() {
        path = []
        onConnectStarted()
    }

    // MARK: Actions

    private func connect(_ record: ConnectionRecord) {
        guard !store.secretsLocked else { return }
        store.setPrimary(record.id)
        Haptics.impact()
        tunnel.connect(record: record)
        onConnectStarted()
    }

    private func verify(_ record: ConnectionRecord) {
        Task {
            await health.verify(record, using: tunnel, force: true)
            if let feedback = health.settledDisplay(for: record.id).finishedCheckFeedback { Haptics.play(feedback) }
        }
    }

    private func remove(_ record: ConnectionRecord) {
        if tunnel.connectedRecord?.id == record.id { tunnel.disconnect() }
        if let i = store.connections.firstIndex(where: { $0.id == record.id }) {
            store.remove(at: IndexSet([i]))
        }
    }

    /// A whole-server connection is rebuilt from its server's protocols, so it
    /// has nothing to share, edit or remove here.
    private func menuItems(_ record: ConnectionRecord) -> [OlcMenuItem] {
        guard !record.isBundle else { return [] }
        return [
            .action(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up") {
                sheet = .share(record)
            },
            .action(L10n.copyURIAction.localized(), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = record.details.shareURI
                LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(record.displayName))
            },
            .action(L10n.actionQR.localized(), systemImage: "qrcode") { sheet = .qr(record) },
            .divider,
            .action(L10n.edit.localized(), systemImage: "pencil") { sheet = .edit(record) },
            .action(L10n.connectRowRemove.localized(), systemImage: "minus.circle", role: .destructive) {
                remove(record)
            },
        ]
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .add:
            AddConnectionView(onImport: { input in
                self.sheet = nil
                onPasteImport?(input)
            }) {
                store.add($0)
            }
        case .edit(let record):
            AddConnectionView(existing: record) { updated in
                store.update(updated)
                if updated.details != record.details { verify(updated) }
            }
        case .qr(let record):
            NavigationStack {
                QRCodeView(uri: record.details.shareURI)
                    .padding(Theme.Metrics.s7)
                    .navigationTitle(ConnectionNaming.listTitle(record))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.actionDone.localized()) { self.sheet = nil }
                        }
                    }
            }
            .presentationDetents([.medium])
        case .share(let record):
            ShareConnectionView(conn: record)
        case .scanner:
            QRScannerSheet { scanned in
                pendingImport = scanned
                self.sheet = nil
            }
        case .link:
            LinkEntrySheet { pendingImport = $0 }
        case .curated:
            CuratedListsView { pendingImport = $0 }
        }
    }

    private func importPending() {
        guard let text = pendingImport else { return }
        pendingImport = nil
        onImportText(text)
    }

    // MARK: Caches and refresh

    /// Runs when the list itself changes, not when a check finishes, so rows
    /// do not jump while a check is running.
    private func recompute() {
        let order = store.subscriptionMeta.keys.sorted { a, b in
            let (ta, tb) = (SubscriptionText.title(source: a, meta: store.subscription(a)),
                            SubscriptionText.title(source: b, meta: store.subscription(b)))
            return ta != tb ? ta.localizedStandardCompare(tb) == .orderedAscending : a < b
        }
        var next = ConnectionSections.make(records: store.connections, hosts: serverStore.hosts,
                                           covered: ServerBundle.coveredIDs(in: store.connections),
                                           showFolded: false, subscriptions: order)
        next.direct = ConnectionSections.byHealth(next.direct) { health.settledDisplay(for: $0) }
        sections = next
        recomputeBest()
        recomputeCounts()
    }

    /// The best-server mark goes only to what automatic choices may pick.
    private func recomputeBest() {
        let best = health.bestChoice(among: store.automaticCandidates.map(\.id))
        if best != bestID { bestID = best }
    }

    private func recomputeCounts() {
        var next: [String: SubscriptionCounts] = [:]
        for subscription in sections.subscriptions {
            let counts = ConnectionSections.counts(subscription.records) { health.settledDisplay(for: $0) }
            next[subscription.source] = SubscriptionCounts(working: counts.working, checked: counts.checked)
        }
        if next != subscriptionCounts { subscriptionCounts = next }
    }

    /// A pull refreshes every switched-on subscription and starts a check of
    /// every connection automatic choices may use. The spinner waits for the
    /// lists only: each row shows its own check, so nothing is held up for it.
    private func refreshEverything() async {
        // What the check on opening covers, each forced: a list of free servers
        // holds hundreds, and checking every one in turn ran for hours.
        let keep = Set(sections.own.flatMap { $0.records.map(\.id) })
            .union([store.primary?.id, tunnel.connectedRecord?.id].compactMap { $0 })
        health.verifyAll(health.automaticSweepCandidates(store.automaticCandidates, keep: keep,
                                                         covered: ServerBundle.coveredIDs(in: store.connections)),
                         using: tunnel)
        if store.hasSubscriptions { _ = await store.refreshAllSources() }
    }
}

// MARK: - SubscriptionSourceRow
//
// The title is provider-supplied free text, so it is drawn as plain text with
// no styling derived from the input.

struct SubscriptionSourceRow: View {
    let title: String
    /// "Servers: 42 · working: 30".
    let counts: String
    /// "Updated today at 14:32"; nil when the list was never fetched.
    let updated: String?
    let isEnabled: Bool
    var isRefreshing = false
    /// The last fetch from the row's button did not bring the list.
    var refreshFailed = false
    /// The list is fetched now; nil hides the button.
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.Metrics.s3) {
            details
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRefresh, isEnabled {
                OlcTapButton(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Theme.Palette.accentTint)
                        }
                    }
                    .frame(width: Theme.Metrics.controlHeight, height: Theme.Metrics.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .accessibilityLabel(L10n.subRefreshNow.localized())
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Metrics.s2) {
                Text(title)
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(2)
                if !isEnabled {
                    Text(L10n.listSubscriptionOff.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Metrics.s2)
                        .padding(.vertical, 2)
                        .background(Theme.Palette.fill, in: Capsule())
                }
            }
            Text(counts)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let updated {
                Text(updated)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if refreshFailed {
                Text(L10n.subRefreshFailedShort.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - BestServerSearchRow

/// Finds a working server among `records` and connects through it — for a list
/// of free servers, which is mostly dead ones.
struct BestServerSearchRow: View {
    @ObservedObject var search: BestServerSearch
    let records: [ConnectionRecord]
    let tunnel: TunnelManager
    let health: HealthCoordinator
    let onFound: (ConnectionRecord) -> Void

    var body: some View {
        OlcTapButton(action: {
            if search.isRunning {
                search.cancel()
            } else {
                search.start(records, tunnel: tunnel, health: health) { onFound($0) }
            }
        }) {
            HStack(spacing: Theme.Metrics.s3) {
                if search.isRunning {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Theme.Palette.accentTint)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(search.isRunning ? L10n.searchStop.localized() : L10n.searchFastest.localized())
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.accentTint)
                    if let status {
                        Text(status)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var status: String? {
        switch search.phase {
        case .idle:                         return nil
        case .knocking(let total):          return L10n.searchKnocking_fmt.formatted(total)
        case .checking(let index, let of):  return L10n.searchChecking_fmt.formatted(index, of)
        case .noneFound:                    return L10n.searchNoneFound.localized()
        }
    }
}

// MARK: - ConnectionListRow

/// One connection: a mark for the one in use, its name, which server (or what
/// went wrong, in the verdict's colour), and one word for whether it works.
///
/// A row keeps its size while checks run: the status sits in a slot as wide as
/// the widest word it can take and as tall as the control, the «best» mark and
/// the re-check spinner live inside that slot, and a value that is being
/// re-measured stays on screen until the new one lands.
struct ConnectionListRow: View {
    let title: String
    let subtitle: String
    let display: HealthDisplay
    /// The connection Connect would use.
    let isSelected: Bool
    /// The connection the tunnel runs through right now.
    let isLive: Bool
    var isBest = false
    /// A new reading is under way; `display` still holds the last one.
    var isRefreshing = false
    /// The rooms of a whole-server connection that did not answer, in the
    /// warning colour; the row itself can still be green.
    var problem: String? = nil
    let menuItems: [OlcMenuItem]
    let onTap: () -> Void
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metrics.s3) {
            OlcTapButton(action: onTap) { info }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityHint(L10n.connectRowTapHint.localized())
            status
            if !menuItems.isEmpty {
                OlcOverflowMenu(items: menuItems)
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
        // A verdict landing from a background check changes words in place;
        // it is never animated as if the person had asked for it.
        .transaction { $0.animation = nil }
    }

    private var info: some View {
        HStack(spacing: Theme.Metrics.s3) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(Theme.Typography.title)
                .foregroundStyle(isSelected ? Theme.Palette.accentTint : Theme.Palette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = display.listProblem ?? (subtitle.isEmpty ? nil : subtitle) {
                    Text(line)
                        .font(Theme.Typography.body)
                        .foregroundStyle(lineColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem)
                        .font(Theme.Typography.body)
                        .foregroundStyle(OlcStatusTone.warn.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    /// The problem in the verdict's colour; "couldn't check" (grey) in the
    /// secondary ink, which stays readable where the tertiary grey would not.
    private var lineColor: Color {
        guard display.listProblem != nil, display.tone != .unknown else { return Theme.Palette.textSecondary }
        return display.tone.color
    }

    @ViewBuilder
    private var status: some View {
        if isLive {
            sized(Text(L10n.listRowConnected.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.green)
                .lineLimit(1))
                .frame(minHeight: Theme.Metrics.controlHeight)
        } else {
            OlcTapButton(action: onVerify) {
                statusContent
                    .frame(minHeight: Theme.Metrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isBest ? "\(display.plainLine). \(L10n.healthBestChoice.localized())"
                                       : display.plainLine)
            .accessibilityHint(L10n.listRowVerifyHint.localized())
        }
    }

    /// A row whose problem is spelled out under its name keeps only the dot
    /// here, so the reason gets the width; every other row has the word slot.
    @ViewBuilder
    private var statusContent: some View {
        if display.listProblem == nil {
            sized(VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: Theme.Metrics.s2) {
                    OlcHealthIndicator(display: display, isRefreshing: isRefreshing)
                    Text(display.listWord)
                        .font(Theme.Typography.body)
                        .foregroundStyle(display.isVerified ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                // Always laid out, drawn only for the best: the mark appearing
                // after a check must not make the row taller or wider.
                OlcBestTag()
                    .opacity(isBest ? 1 : 0)
                    .accessibilityHidden(true)
            })
        } else {
            OlcHealthIndicator(display: display, isRefreshing: isRefreshing)
        }
    }

    /// The words the status can take, so its slot is as wide as the widest of
    /// them and a verdict or a re-check never changes the width left to the name.
    private static var statusWords: [String] {
        [L10n.listRowConnected.localized(), L10n.listWordNotWorking.localized(),
         L10n.healthChipNotChecked.localized(), L10n.healthChecking.localized(),
         L10n.healthVerified.localized(), L10n.healthLatencyMs_fmt.formatted(888)]
    }

    private func sized<Content: View>(_ content: Content) -> some View {
        ZStack(alignment: .trailing) {
            ForEach(Array(Self.statusWords.enumerated()), id: \.offset) { _, word in
                Text(word)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                    .padding(.leading, OlcHealthDotMetrics.halo + Theme.Metrics.s2)
                    .hidden()
            }
            content
        }
    }
}
