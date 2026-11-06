import SwiftUI

// MARK: - ConnectionsView — the Home tab
//
// JOB: say whether the tunnel is up, offer the ONE action that changes it, and
// name the connection it uses. Every connection is listed on the Servers tab
// (ConnectionListView), one tap away from the hero's "Choose another server".
//
// Top to bottom:
//   1. ConnectHero  — the state as the largest text on the screen, one plain
//                     line under it, the firewall picture, one labelled button,
//                     then the connection it uses with its menu.
//   2. Connection check — one row; the readouts ("This session": exit and
//                     latency while connected; "Checks": IP check, speed test,
//                     HealthCard.swift) are one push away, not on the main screen.
//
// Checks run once when the app opens and on every connect; a pull checks every
// connection again and refreshes the subscriptions.
//
// Surgery discipline: this file has hit the SwiftUI type-checker's expression
// budget twice. Every change is by EXTRACTION — the hero lives in
// ConnectHero.swift, the diagnostics card in HealthCard.swift, throughput
// sampling in TunnelThroughput.swift, and the List's modifiers are split across
// small wrapper functions. Nothing here has a `body` over ~20 lines or a chain
// over ~8.

struct ConnectionsView: View {
    @ObservedObject var store   : ConnectionStore
    @ObservedObject var tunnel  : TunnelManager
    @ObservedObject var ipCheck : IPChecker
    @ObservedObject var speed   : SpeedTest
    /// #361: routes a subscription pasted into the AddConnection import box (an
    /// https URL or raw sub.md body) up to MainTabView's confirm-then-import flow.
    var onPasteImport: ((OlcrtcSubscription.ImportInput) -> Void)? = nil
    /// Text pasted, scanned or read from a file (the first-run screen and the
    /// «+» menu) and the user's own server — both handled by MainTabView.
    var onImportText: ((String) -> Void)? = nil
    var onAddServer: (() -> Void)? = nil
    /// Opens the Servers tab, where every connection is listed.
    var onChooseServer: (() -> Void)? = nil
    /// Opens My servers, where a stale server core is updated.
    var onOpenMyServers: (() -> Void)? = nil
    /// Labels of the user's servers that run another core than this app.
    var staleServers: [String] = []
    /// IDs of records some saved server produced; anything else was imported
    /// from another device and cannot be repaired from "My servers" here.
    var linkedRecordIDs: Set<UUID> = []

    // #337: observe the screenshot-safe toggle so IP displays re-mask live.
    // #457: also the source of `tunnelMode` for the hero's permanent scope line.
    @ObservedObject private var settings = SettingsStore.shared
    // #456: the ONE health vocabulary — a singleton because it is written by
    // non-view code (TunnelManager) and read by two tabs.
    @ObservedObject private var health = HealthCoordinator.shared

    // #330: ONE enum-driven sheet. Multiple `.sheet` modifiers on one view is
    // unsupported in SwiftUI and, when the host re-renders under a live tunnel,
    // the editor sheet hangs on present and on dismiss.
    @State private var activeSheet: ConnectionSheet?
    /// Text a sheet brought in, imported once the sheet has gone.
    @State private var pendingImport: String?
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var importError: String?

    // boc #486: user intent belongs to this visible screen, not a tunnel-wide
    // state observer. Tab changes, sheets and backgrounding discard it.
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var hapticPolicy = SignalHapticPolicy()
    // eoc #486

    /// Polls tunnel byte counters ~1/s for the hero — only while connected, on
    /// screen, uncovered and in the foreground (`syncThroughput`).
    @StateObject private var throughput = TunnelThroughputMonitor()
    /// The connection check's per-protocol speeds (`protocolCheckSection`).
    @StateObject private var protocolCheck = ProtocolSpeedCheck()

    /// The connection with the best fresh round trip (`BestChoice`), marked on
    /// the hero. Recomputed when a verdict changes, not in `body`.
    @State private var bestID: UUID?

    /// #330: the single sheet this view can present.
    private enum ConnectionSheet: Identifiable {
        case add
        case edit(ConnectionRecord)
        case qr(ConnectionRecord)
        case carrierEndpoints(OlcrtcConnection)   // #406
        case share(ConnectionRecord)              // #456
        case scanner
        case link
        case curated

        var id: String {
            switch self {
            case .add:              return "add"
            case .edit(let c):      return "edit-\(c.id.uuidString)"
            case .qr(let c):        return "qr-\(c.id.uuidString)"
            case .carrierEndpoints: return "carrier"
            case .share(let c):     return "share-\(c.id.uuidString)"
            case .scanner:          return "scanner"
            case .link:             return "link"
            case .curated:          return "curated"
            }
        }
    }

    // #484 was: connected proxy ? .tunnel : .direct. VPN uses ordinary sockets
    // but is NOT direct provenance; the distinction also invalidates old ISP IPs.
    private var currentMode: RouteMode {
        RouteMode.current(isConnected: tunnel.state.isConnected, activeMode: tunnel.activeMode)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            importWiring(listWiring(listBars(listChrome(connectionList))))
        }
        // #459: the manual equivalent of the pull, on entry — governed by the
        // "Check on opening" switch. THE TOGGLE DECIDES WHETHER THE APP CHECKS
        // BY ITSELF; A PULL ALWAYS CHECKS.
        // boc #486
        .onAppear {
            isVisible = true
            Haptics.prepare()
            entrySweep()
            syncThroughput()
        }
        .onDisappear {
            isVisible = false
            hapticPolicy.cancel()
            throughput.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hapticPolicy.cancel() }
            else if isVisible { Haptics.prepare() }
            syncThroughput()
        }
        .onChange(of: activeSheet?.id) { _, id in
            if id != nil { hapticPolicy.cancel() }
            else if isVisible { Haptics.prepare() }
            syncThroughput()
        }
        // eoc #486
        // #484: same-state record/mode replacement also invalidates diagnostics.
        .onChange(of: tunnel.connectedRecord?.id) { _, _ in invalidateDiagnostics() }
        // Another record carries other lanes: the monitor takes their names.
        .onChange(of: tunnel.connectedRecord?.id) { _, _ in syncThroughput() }
        .onChange(of: tunnel.activeMode) { _, _ in invalidateDiagnostics(); syncThroughput() }
    }

    /// ONE PAGE: the answer, the control, the connection it uses, then the
    /// readouts one deliberate scroll down.
    @ViewBuilder
    private var connectionList: some View {
        if store.connections.isEmpty {
            // Nothing to connect to yet: the hero would animate a wall for no
            // connection. Offer the ways in instead.
            WelcomeView(onImportText: { onImportText?($0) },
                        onAddServer: { onAddServer?() },
                        onManual: { activeSheet = .add },
                        onCurated: { activeSheet = .curated })
        } else {
            List {
                Section { heroBlock }
                lanesSection
                staleServersSection
                diagnosticsSection
            }
        }
    }

    private func listChrome(_ content: some View) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.bg)
            .refreshable { await refreshEverything() }
    }

    // boc #460
    /// #460: both system bars draw their background, so a scrolled `List` is
    /// covered by them instead of showing through; the bottom margin gives the
    /// last card room above the tab bar.
    private func listBars(_ content: some View) -> some View {
        content
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            .contentMargins(.bottom, Theme.Metrics.s6, for: .scrollContent)
            .listSectionSpacing(Theme.Metrics.s4)
    }
    // eoc #460

    private func listWiring(_ content: some View) -> some View {
        content
            .onChange(of: store.connections, initial: true) { _, _ in recomputeBest() }
            .onChange(of: health.revision) { _, _ in recomputeBest() }
            .onChange(of: tunnel.state) { old, new in stateChanged(from: old, to: new) }
            .navigationTitle(L10n.tabHome.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { addMenu } }
            .sheet(item: $activeSheet, onDismiss: importPending) { sheetContent($0) }
    }

    /// The file picker and its error, off the other chains for the type-checker.
    private func importWiring(_ content: some View) -> some View {
        content
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: ImportFile.contentTypes) { result in
                switch ImportFile.read(result) {
                case .text(let text):       onImportText?(text)
                case .failure(let message): importError = message
                }
            }
            .photoQRImport(isPresented: $showPhotoPicker,
                           onResult: { onImportText?($0) },
                           onFailure: { importError = $0 })
            .alert(L10n.okPrompt.localized(),
                   isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button(L10n.ok.localized()) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    private var addMenu: some View {
        AddSourcesMenu(onPaste: { onImportText?(UIPasteboard.general.string ?? "") },
                       onScan: { activeSheet = .scanner },
                       onPhoto: { showPhotoPicker = true },
                       onFile: { showFilePicker = true },
                       onLink: { activeSheet = .link },
                       onCurated: { activeSheet = .curated },
                       onManual: { activeSheet = .add },
                       onOwnServer: { onAddServer?() })
    }

    private func importPending() {
        guard let text = pendingImport else { return }
        pendingImport = nil
        onImportText?(text)
    }

    // MARK: 1. Hero

    /// While the session runs over several rooms: what each one carries now.
    @ViewBuilder
    private var lanesSection: some View {
        if tunnel.state.isConnected, throughput.lanes.count > 1 {
            Section {
                LaneTrafficPanel(lanes: throughput.lanes)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var heroBlock: some View {
        ConnectHero(state: tunnel.state,
                    subject: heroSubject,
                    health: heroSubject.map { heroHealth($0) } ?? HealthDisplay.never,
                    exitFlag: exitFlag,
                    exitPlace: exitPlace,
                    // Setup/recovery keep their captured backend; idle scope
                    // previews the same effective mode that connect() will use.
                    mode: heroMode,
                    socksPort: tunnel.boundPort ?? settings.socksPort,
                    secretsLocked: store.secretsLocked,
                    isPresented: isVisible && activeSheet == nil,
                    modeFallbackReason: heroMode == .proxy ? tunnel.automaticModeFallbackReason : nil,
                    isManagedHere: heroSubject.map { linkedRecordIDs.contains($0.id) } ?? true,
                    isBest: heroSubjectID != nil && heroSubjectID == bestID,
                    isReconnecting: tunnel.showsReconnecting,
                    throughput: throughput.reading,
                    waveIntensity: throughput.intensity,
                    menuItems: heroSubject.map { menuItems($0) } ?? [],
                    onConnect: { heroConnect() },
                    onDisconnect: { heroDisconnect() },
                    onChoose: store.connections.count > 1 ? onChooseServer : nil)
            // Signal sits on the page ground; only the connection summary is a
            // plate. No side inset of its own: the plate and the button line up
            // with the cards below, which sit flush with the section margin.
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Theme.Metrics.s2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// The mode the hero describes. Proxy mode needs no card of its own: the
    /// hero's scope line says what "Connected" covers, a fallback from VPN is
    /// told by the hero's own disclosure line (`modeFallbackReason`), Telegram
    /// is in Settings, and the bypass list is in the hero's menu.
    private var heroMode: TunnelMode {
        switch tunnel.state {
        case .connected, .connecting, .waitingForNetwork: return tunnel.activeMode
        case .failed where tunnel.hasPendingRecovery: return tunnel.activeMode
        case .disconnected, .failed: return tunnel.effectiveModeForNextConnection
        }
    }

    /// The throughput monitor runs only while there is something to measure and
    /// someone to see it. Every input change funnels through here; anything
    /// else stops the loop and clears the reading.
    private func syncThroughput() {
        throughput.update(isConnected: tunnel.state.isConnected,
                          isOnScreen: isVisible && activeSheet == nil,
                          sceneIsActive: scenePhase == .active,
                          mode: tunnel.activeMode,
                          vpn: tunnel.vpn,
                          laneNames: LaneReading.names(of: tunnel.connectedRecord,
                                                       inVPN: tunnel.activeMode == .vpn))
    }

    /// #456: the record the hero describes — the LIVE node while a session is up,
    /// else the engaged attempt or the last chosen one, which is also the node a
    /// Connect tap will dial.
    private var heroSubject: ConnectionRecord? {
        if tunnel.state.isConnected { return tunnel.connectedRecord }
        return tunnel.engagedRecord ?? store.primary
    }

    private var heroSubjectID: UUID? { heroSubject?.id }

    /// The same verdict the connection's row shows: a whole-server connection
    /// stands on the rooms it joins as well as on its own check.
    private func heroHealth(_ record: ConnectionRecord) -> HealthDisplay {
        record.isBundle ? health.bundleDisplay(for: record, among: store.connections)
                        : health.settledDisplay(for: record.id)
    }

    /// #459: the exit as the hero prints it — "Amsterdam, NL". nil whenever the
    /// lookup gave nothing usable.
    private var exitPlace: String? {
        guard let geo = ipCheck.exitGeo, geo != IPChecker.ExitGeo() else { return nil }
        let place = [geo.city, geo.country].compactMap { $0 }.joined(separator: ", ")
        return place.isEmpty ? nil : place
    }

    private var exitFlag: String? {
        guard let cc = ipCheck.exitGeo?.country else { return nil }
        return CountryFlag.emoji(iso2: cc)
    }

    private func heroConnect() {
        // boc #486
        guard let p = store.primary, !store.secretsLocked else { return }
        beginUserConnection(p)
        // eoc #486
    }

    private func heroDisconnect() {
        // #486: cancellation has one press impact, never a later success buzz.
        hapticPolicy.cancel()
        Haptics.impact()
        tunnel.disconnect()
    }

    /// #455: physical feedback on the OUTCOME — success only after `verifyTunnel`
    /// returned 200, an error buzz when the attempt gives up. #454: the exit geo is
    /// fetched on the connect transition and cleared on the way down.
    private func stateChanged(from old: ConnectionState, to new: ConnectionState) {
        invalidateDiagnostics() // #484: includes connecting/waiting, not only disconnect.
        resolveUserOutcome()
        syncThroughput()
        if new.isConnected {
            Task { await ipCheck.refreshExitGeo(via: currentMode) }
        } else {
            ipCheck.clearExitGeo()
        }
    }

    // boc #486
    private func beginUserConnection(_ record: ConnectionRecord) {
        guard isVisible, scenePhase == .active, activeSheet == nil,
              !store.secretsLocked else { return }
        // #486: the manager deliberately ignores an already-engaged identical
        // choice. A no-op must not masquerade as a new successful connection.
        if tunnel.engagedRecord?.id == record.id,
           tunnel.activeMode == tunnel.effectiveModeForNextConnection {
            switch tunnel.state {
            case .connected, .connecting, .waitingForNetwork: return
            case .disconnected, .failed: break
            }
        }
        hapticPolicy.beginConnection(id: record.id)
        Haptics.impact()
        tunnel.connect(record: record)
        // Preflight can fail synchronously, even with the same error text as a
        // previous retry (no onChange). Consume now as well; the policy is once-only.
        resolveUserOutcome()
    }

    private func resolveUserOutcome() {
        let phase: SignalConnectionPhase
        switch tunnel.state {
        case .disconnected: phase = .idle
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        case .waitingForNetwork: phase = .waiting
        case .failed: phase = .failed
        }
        let outcome = hapticPolicy.outcome(
            phase: phase, connectedRecordID: tunnel.connectedRecord?.id,
            isVisible: isVisible && activeSheet == nil,
            sceneIsActive: scenePhase == .active,
            isAutomaticRecovery: tunnel.hasPendingRecovery)
        switch outcome {
        case .success: Haptics.success()
        case .error: Haptics.error()
        case nil: break
        }
    }
    // eoc #486

    // boc #484: App.swift also invokes these on lifecycle transitions while this
    // view is absent. Generation guards make late network completions harmless.
    private func invalidateDiagnostics() {
        ipCheck.invalidateRoute()
        speed.invalidateRoute()
    }
    // eoc #484

    // MARK: A server that needs its core updated

    @ViewBuilder
    private var staleServersSection: some View {
        if !staleServers.isEmpty, let onOpenMyServers {
            Section {
                OlcTapButton(action: onOpenMyServers) {
                    HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                            Text(L10n.coreStaleTitle_fmt.formatted(staleServers.joined(separator: ", ")))
                                .font(Theme.Typography.bodyStrong)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.coreStaleBody.localized())
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, Theme.Metrics.s2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .signalFormRows()
        }
    }

    // MARK: 2. The connection check — one push away (HealthCard.swift)

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                diagnosticsScreen
            } label: {
                SignalSettingsLabel(L10n.diagnosticsTitle.localized(),
                                    subtitle: L10n.diagnosticsRowSubtitle.localized(),
                                    systemImage: "speedometer")
            }
        }
        .signalFormRows()
    }

    private var diagnosticsScreen: some View {
        List {
            Section {
                DiagnosticsCard(record: tunnel.connectedRecord,
                                ipCheck: ipCheck, speed: speed,
                                mode: currentMode, maskIPs: settings.maskIPs,
                                isConnected: tunnel.state.isConnected,
                                onSpeedTest: { runSpeedTest() })
                    // #484: checks during route installation cannot be attributed.
                    .disabled(tunnel.state.isConnecting || tunnel.state == .waitingForNetwork)
                    .olcCardRow()
            }
            protocolCheckSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.bg)
        .navigationTitle(L10n.diagnosticsTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { protocolCheck.cancel() }
        .onChange(of: tunnel.state.isConnected) { _, connected in
            if !connected { protocolCheck.cancel() }
        }
    }

    /// While the session runs over several rooms: each one's speed on its own,
    /// then all of them together.
    @ViewBuilder
    private var protocolCheckSection: some View {
        let targets = protocolTargets
        if !targets.isEmpty {
            Section {
                ProtocolCheckCard(check: protocolCheck,
                                  onRunAll: {
                                      protocolCheck.run(targets, credentials: TunnelManager.liveSocksCredentials)
                                  },
                                  onRunOne: { id in
                                      guard let target = targets.first(where: { $0.id == id }) else { return }
                                      protocolCheck.run([target], credentials: TunnelManager.liveSocksCredentials)
                                  })
                    .olcCardRow()
                    .onAppear { protocolCheck.prepare(targets) }
            }
        }
    }

    /// The live session's own lanes and the shared port; nothing for one room
    /// or the system VPN.
    private var protocolTargets: [ProtocolSpeedCheck.Target] {
        guard tunnel.state.isConnected, tunnel.activeMode == .proxy, let port = tunnel.boundPort else { return [] }
        let ports = OlcrtcEngine.shared.lanePorts()
        let names = LaneReading.names(of: tunnel.connectedRecord)
        guard ports.count > 1, ports.count == names.count else { return [] }
        var targets = ports.enumerated().map { index, lanePort in
            ProtocolSpeedCheck.Target(id: index, name: LaneReading.name(at: index, in: names), port: lanePort)
        }
        targets.append(ProtocolSpeedCheck.Target(id: ProtocolSpeedCheck.allTogether,
                                                  name: L10n.protoCheckAllTogether.localized(), port: port))
        return targets
    }

    /// #285: pass the LIVE carrier/transport into the speed test so the header logs
    /// the connection type and the datachannel hint can fire.
    private func runSpeedTest() {
        var carrier: String?
        var transport: String?
        if currentMode.isTunnelled, case .olcrtc(let p)? = tunnel.connectedRecord?.details { // #484
            carrier = p.carrier
            transport = p.transport
        }
        Task { await speed.run(via: currentMode, carrier: carrier, transport: transport) }
    }

    // MARK: The hero's menu

    /// The hero's subject carries the actions a row on the Servers tab has.
    /// A whole-server connection is rebuilt from its server's protocols, so it
    /// has nothing to share, edit or remove; only the carrier-endpoints tool.
    private func menuItems(_ conn: ConnectionRecord) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = []
        if !conn.isBundle {
            // #456: connection-ONLY share — the `olcrtc://` URI and nothing else,
            // so it grants NO VPS/SSH access.
            items.append(.action(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up") {
                activeSheet = .share(conn)
            })
            items.append(.divider)
            items.append(.action(L10n.copyURIAction.localized(), systemImage: "doc.on.doc") {
                SecretPasteboard.copy(conn.details.shareURI)
                LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
            })
            items.append(.action(L10n.actionQR.localized(), systemImage: "qrcode") {
                activeSheet = .qr(conn)
            })
        }
        carrierEndpointsItem(conn, into: &items)
        if !conn.isBundle {
            items.append(.divider)
            items.append(.action(L10n.edit.localized(), systemImage: "pencil") { activeSheet = .edit(conn) })
            items.append(.action(L10n.connectRowRemove.localized(),
                                 systemImage: "minus.circle", role: .destructive) {
                remove(conn)
            })
        }
        return items
    }

    /// #461: "which addresses does THIS carrier need let out directly?" — only
    /// the live connection has an answer, so the item appears for it alone.
    private func carrierEndpointsItem(_ conn: ConnectionRecord, into items: inout [OlcMenuItem]) {
        guard case .olcrtc(let params) = conn.details,
              conn.id == tunnel.connectedRecord?.id else { return }
        if !items.isEmpty { items.append(.divider) }
        items.append(.action(L10n.carrierEndpointsRowTitle.localized(),
                             systemImage: "arrow.triangle.branch") {
            activeSheet = .carrierEndpoints(params)
        })
    }

    private func verify(_ conn: ConnectionRecord) {
        Task { await health.verify(conn, using: tunnel, force: true) }
    }

    private func remove(_ conn: ConnectionRecord) {
        // #470: a record that no longer exists cannot stay connected honestly.
        if tunnel.connectedRecord?.id == conn.id { tunnel.disconnect() }
        if let i = store.connections.firstIndex(where: { $0.id == conn.id }) {
            store.remove(at: IndexSet([i]))
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ConnectionSheet) -> some View {
        switch sheet {
        case .add:
            AddConnectionView(onImport: { input in
                activeSheet = nil   // hand off to the subscription confirm flow
                onPasteImport?(input)
            }) {
                store.add($0)
            }
        case .edit(let conn):
            AddConnectionView(existing: conn) { updated in
                store.update(updated)
                // #470: a changed `details` is unmeasured until proven otherwise.
                if updated.details != conn.details { verify(updated) }
            }
        case .qr(let conn):
            qrSheet(conn)
        case .carrierEndpoints(let params):
            CarrierEndpointsView(params: params)
        case .share(let conn):
            ShareConnectionView(conn: conn)
        case .scanner:
            QRScannerSheet { scanned in
                pendingImport = scanned
                activeSheet = nil
            }
        case .link:
            LinkEntrySheet { pendingImport = $0 }
        case .curated:
            CuratedListsView { pendingImport = $0 }
        }
    }

    private func qrSheet(_ conn: ConnectionRecord) -> some View {
        NavigationStack {
            QRCodeView(uri: conn.details.shareURI)
                .padding(Theme.Metrics.s7)
                .navigationTitle(ConnectionNaming.listTitle(conn))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.actionDone.localized()) { activeSheet = nil }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    // MARK: Caches

    /// Which connection to recommend, from the stored verdicts.
    private func recomputeBest() {
        let best = health.bestChoice(among: store.automaticCandidates.map(\.id))
        if best != bestID { bestID = best }
    }

    // MARK: Refresh — the pull

    /// A pull refreshes the state of everything: every connection's health
    /// probe (forced — a pull is an explicit request), the tunnel's exit place
    /// while a session is up, and every subscription source. The spinner waits
    /// for the exit place and the lists only; each row shows its own check.
    private func refreshEverything() async {
        health.verifyAll(pullCandidates, using: tunnel)
        if tunnel.state.isConnected {
            await ipCheck.refreshExitGeo(via: currentMode)
        }
        if store.hasSubscriptions { _ = await store.refreshAllSources() }
    }

    /// What a pull checks: what the check on opening covers, each forced. A list
    /// of free servers holds hundreds, and checking every one in turn ran for
    /// hours; the rest are for the search for the fastest.
    private var pullCandidates: [ConnectionRecord] {
        let keep = linkedRecordIDs.union([store.primary?.id, tunnel.connectedRecord?.id].compactMap { $0 })
        return health.automaticSweepCandidates(store.automaticCandidates, keep: keep,
                                               covered: ServerBundle.coveredIDs(in: store.connections))
    }

    /// The check on opening: once per foreground session, gated on the
    /// "Check on opening" switch. A pull always checks.
    private func entrySweep() {
        guard settings.refreshOnEntry else { return }
        guard health.claimAutomaticSweep() else { return }
        let keep = linkedRecordIDs.union([store.primary?.id, tunnel.connectedRecord?.id].compactMap { $0 })
        health.verifyDue(health.automaticSweepCandidates(store.automaticCandidates, keep: keep,
                                                         covered: ServerBundle.coveredIDs(in: store.connections)),
                         using: tunnel)
    }
}

// Both appearance variants.
#if DEBUG
#Preview("Home — Dark") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.dark)
}
#Preview("Home — Light") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.light)
}
#endif
