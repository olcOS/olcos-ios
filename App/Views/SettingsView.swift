import SwiftUI

// MARK: - SettingsView
//
// The third tab. Everything a person uses is visible in its group; the rare
// and technical are one push away on `SettingsAdvancedView`, the last row.
// Groups, top to bottom:
//
//   Connection · Rooms · Accounts · Network · Speed · Diagnostics ·
//   Appearance · About · Advanced
//
// One home per setting. Conventions shared with every Form in the app: the
// token ground via `.signalFormChrome()`, a `TunnelSettingsNote` directly under
// the control it explains, and a section footer only where it adds information
// about the whole section. Reads/writes go through `SettingsStore.shared`,
// which mirrors UserDefaults; SwiftUI rebinds on @Published changes.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// Live tunnel state: the mode picker's lock, the VPN capability probe and
    /// the port handed to Telegram.
    @ObservedObject var tunnel: TunnelManager
    /// The per-server stores the log reader and the room exceptions need.
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore

    @State private var showResetConfirm = false
    @State private var socksPassInput: String = ""
    @State private var socksPassLoaded = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            // The modifier stack is split across two small wrappers so no single
            // expression carries the whole chain (type-checker budget).
            formWiring(formChrome(settingsForm))
        }
    }

    private var settingsForm: some View {
        Form {
            TunnelSettingsModeSection(tunnel: tunnel)
            connectionSection
            roomsSection
            ServiceAccountsSections()
            networkSection
            speedSection
            diagnosticsSection
            appearanceSection
            aboutSection
            advancedSection
        }
    }

    private func formChrome(_ content: some View) -> some View {
        content
            .signalFormChrome()
            .refreshable { await refreshSettings() }
            // Side-effect free: only reads existing VPN preferences, never pops
            // the system consent alert. Drives the VPN chip in the mode section.
            .task { await tunnel.vpn.probeCapability() }
            .onDisappear { socksPassLoaded = false }
    }

    private func formWiring(_ content: some View) -> some View {
        content
            .confirmationDialog(L10n.resetSettingsConfirmTitle.localized(),
                                isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button(L10n.resetSettingsAction.localized(), role: .destructive) {
                    SettingsStore.shared.reset()
                    Haptics.success()
                }
                Button(L10n.cancel.localized(), role: .cancel) { }
            } message: {
                Text(L10n.resetSettingsConfirmBody.localized())
            }
            .navigationTitle(L10n.settingsTitle.localized())
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.done.localized()) { fieldFocused = false }
                }
            }
    }

    /// Pull to refresh: the one thing that goes stale while this screen is open
    /// is whether this install may run the system VPN at all.
    private func refreshSettings() async {
        await tunnel.vpn.probeCapability()
    }

    // MARK: Connection

    /// The rest of the Connection group, under the mode: what happens when the
    /// app opens, keeping a session alive in the background, and what only the
    /// system VPN does (turn on by itself, bond a whole server's rooms).
    /// Automatic switching (`SettingsStore.autoFailover`, default on) is the
    /// switch on the Servers tab, beside the connections it moves between.
    private var connectionSection: some View {
        Section {
            Toggle(L10n.autoConnectOnLaunchLabel.localized(), isOn: $settings.autoConnectOnLaunch)
            TunnelSettingsNote(text: L10n.autoConnectOnLaunchNote.localized())
            Toggle(L10n.settingsRefreshOnEntryToggle.localized(), isOn: $settings.refreshOnEntry)
            TunnelSettingsNote(text: L10n.settingsRefreshOnEntryExplainer.localized())
            Toggle(L10n.settingsBackgroundLabel.localized(), isOn: $settings.backgroundAudio)
            TunnelSettingsNote(text: L10n.backgroundAudioNote.localized())
            NavigationLink {
                AutoConnectView(vpn: tunnel.vpn)
            } label: {
                SignalSettingsLabel(L10n.autoConnectTitle.localized(),
                                    subtitle: settings.vpnOnDemandRules == nil ? L10n.autoConnectOff.localized()
                                                                               : L10n.autoConnectOn.localized(),
                                    systemImage: "bolt.horizontal.circle")
            }
            Toggle(L10n.vpnBondingToggle.localized(), isOn: $settings.vpnBonding)
            TunnelSettingsNote(text: L10n.vpnBondingNote.localized())
        }
        .signalFormRows()
    }

    // MARK: Rooms

    /// One row per protocol showing its rule compactly ("Daily · at night"),
    /// the pickers one push away; then the connections the user can exclude.
    /// It applies only to connections whose server this phone manages.
    @ViewBuilder
    private var roomsSection: some View {
        Section {
            ForEach(RoomRotationRule.carriers, id: \.self) { carrier in
                NavigationLink {
                    RoomRotationRuleView(carrier: carrier)
                } label: {
                    LabeledContent(CarrierTransportMatrix.carrierLabel(carrier),
                                   value: RoomRotationRule.summary(settings.roomRotationRule(for: carrier),
                                                                   window: settings.roomRotationWindow(for: carrier)))
                }
            }
        } header: {
            SignalSectionHeader(L10n.settingsGroupRooms.localized())
        } footer: {
            Text(L10n.roomRotationFooter.localized())
        }
        .signalFormRows()
        rotationExceptions
    }

    /// The connections that can be excluded: those this phone manages whose
    /// protocol is switched on. Nothing is listed while no rule is on.
    @ViewBuilder
    private var rotationExceptions: some View {
        let candidates = RoomRotationPolicy.exceptionCandidates(
            in: connections.connections, hosts: serverStore.hosts,
            ruleIsOn: { settings.roomRotationRule(for: $0).isOn })
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { record in
                    Toggle(isOn: skipBinding(record.id)) {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                            Text(record.displayName)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(skipCaption(record))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            } header: {
                SignalSectionHeader(L10n.roomRotationExceptionsHeader.localized())
            } footer: {
                Text(L10n.roomRotationExceptionsFooter.localized())
            }
            .signalFormRows()
        }
    }

    private func skipCaption(_ record: ConnectionRecord) -> String {
        let action = L10n.roomRotationSkipConnection.localized()
        guard case .olcrtc(let params) = record.details else { return action }
        return "\(CarrierTransportMatrix.carrierLabel(params.carrier)) · \(action)"
    }

    private func skipBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.roomRotationExceptions.contains(id) },
            set: { skip in
                if skip { settings.roomRotationExceptions.insert(id) }
                else    { settings.roomRotationExceptions.remove(id) }
            })
    }

    // MARK: Network

    /// Which sites skip the tunnel, the addresses another proxy app must send
    /// direct, the resolver, and the local proxy: its login and the one-tap
    /// hand-off to Telegram. The port itself is in Advanced.
    @ViewBuilder
    private var networkSection: some View {
        Section {
            NavigationLink {
                RoutingView(tunnel: tunnel)
            } label: {
                SignalSettingsLabel(L10n.routingTitle.localized(),
                                    subtitle: settings.routingMode.title,
                                    systemImage: "arrow.triangle.branch")
            }
            NavigationLink {
                CarrierEndpointsPickerView(connections: connections)
            } label: {
                SignalSettingsLabel(L10n.carrierEndpointsScreenTitle.localized(),
                                    subtitle: L10n.settingsConnectionsCount_fmt.formatted(connections.connections.count),
                                    systemImage: "arrow.uturn.right")
            }
            NavigationLink {
                DNSSettingsView()
            } label: {
                SignalSettingsLabel(L10n.sectionDNS.localized(), subtitle: dnsSummary, systemImage: "globe")
            }
            Button { useInTelegram() } label: {
                Label(L10n.telegramProxyAction.localized(), systemImage: "paperplane.fill")
            }
            .accessibilityHint(L10n.telegramProxyHint.localized())
            Toggle(L10n.localSocksAuthLabel.localized(), isOn: $settings.localSocksAuthEnabled)
            TunnelSettingsNote(text: L10n.socksAuthFooter.localized())
            if settings.localSocksAuthEnabled {
                authFields
            }
        } header: {
            SignalSectionHeader(L10n.settingsGroupNetwork.localized())
        }
        .signalFormRows()
    }

    /// "Cloudflare · 1.1.1.1:53" when the value matches a preset, else the raw value.
    private var dnsSummary: String {
        let v = settings.dnsServer
        let presets: [(String, String)] = AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
        if let hit = presets.first(where: { $0.1 == v }) { return "\(hit.0) · \(v)" }
        return v
    }

    /// Hands the local SOCKS5 proxy to Telegram in one tap (its own "Enable
    /// proxy?" sheet) or, without Telegram installed, to the t.me page that
    /// offers it. The link is never logged: it may carry the local login.
    private func useInTelegram() {
        TelegramProxyOpener.open(port: tunnel.boundPort ?? settings.socksPort, settings: settings)
    }

    @ViewBuilder
    private var authFields: some View {
        TextField(L10n.socksUserLabel.localized(), text: $settings.localSocksUser)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($fieldFocused)
        SecureField(L10n.socksPassLabel.localized(), text: $socksPassInput)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($fieldFocused)
            .onAppear {
                if !socksPassLoaded {
                    socksPassInput = settings.localSocksPass
                    socksPassLoaded = true
                }
            }
            .onChange(of: socksPassInput) { _, v in
                settings.localSocksPass = v
            }
    }

    // MARK: Speed

    /// The VP8 transport's two numbers; out-of-range values are clamped by
    /// `SettingsStore`.
    private var speedSection: some View {
        Section {
            SettingsNumberField(title: L10n.vp8FpsLabel.localized(), value: $settings.vp8FPS,
                                focus: $fieldFocused)
            SettingsNumberField(title: L10n.vp8BatchLabel.localized(), value: $settings.vp8BatchSize,
                                focus: $fieldFocused)
        } header: {
            SignalSectionHeader(L10n.settingsGroupSpeed.localized())
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                Text(L10n.vp8Note.localized())
                Text(L10n.vp8MtsLinkNote.localized())
            }
        }
        .signalFormRows()
    }

    // MARK: Diagnostics

    /// The unscoped way into the log reader; the log knobs are in Advanced.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                LogsView(subject: .all, serverStore: serverStore, connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsViewLogsRow.localized(), systemImage: "doc.text")
            }
        } header: {
            SignalSectionHeader(L10n.settingsGroupDiagnostics.localized())
        }
        .signalFormRows()
    }

    // MARK: Appearance

    /// Text size follows the iOS setting (Dynamic Type); the app has no slider
    /// of its own.
    private var appearanceSection: some View {
        Section {
            Picker(L10n.themeLabel.localized(), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker(L10n.languageLabel.localized(), selection: languageBinding) {
                ForEach(AppLocale.allCases) { locale in
                    Text(locale.displayName).tag(locale)
                }
            }
            // Screenshot-safe mode: display-only masking of IP addresses.
            Toggle(L10n.maskIPsLabel.localized(), isOn: $settings.maskIPs)
            TunnelSettingsNote(text: L10n.maskIPsFooter.localized())
            // Everything olcOS shows outside the app, one push away: the live
            // card on the Lock Screen, the widgets and the Control Centre button.
            NavigationLink {
                WidgetSettingsView()
            } label: {
                SignalSettingsLabel(L10n.settingsSectionWidgets.localized(),
                                    subtitle: settings.liveActivity ? L10n.widgetsRowOn.localized()
                                                                    : L10n.widgetsRowOff.localized(),
                                    systemImage: "rectangle.3.group")
            }
        } header: {
            SignalSectionHeader(L10n.settingsGroupLook.localized())
        }
        .signalFormRows()
    }

    /// Extracted so the language `Picker` stays one short expression.
    private var languageBinding: Binding<AppLocale> {
        Binding(get: { AppLocale(rawValue: settings.language) ?? .english },
                set: { locale in
                    guard settings.language != locale.rawValue else { return }
                    Haptics.tap()
                    settings.language = locale.rawValue
                })
    }

    // MARK: About

    /// The version, the licences and the one destructive row in Settings.
    private var aboutSection: some View {
        Section {
            versionRow
            NavigationLink {
                LicensesView()
            } label: {
                SignalSettingsLabel(L10n.licensesTitle.localized(), systemImage: "doc.plaintext")
            }
            Button(L10n.resetSettingsAction.localized(), role: .destructive) {
                showResetConfirm = true
            }
        } header: {
            SignalSectionHeader(L10n.settingsSectionAbout.localized())
        } footer: {
            Text(L10n.resetSettingsFooter.localized())
        }
        .signalFormRows()
    }

    /// The one door to everything a user rarely tunes, at the very end.
    private var advancedSection: some View {
        Section {
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel,
                                     serverStore: serverStore, connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsAdvancedRow.localized(), systemImage: "slider.horizontal.3")
            }
        }
        .signalFormRows()
    }

    private var versionRow: some View {
        HStack {
            Text("olcOS")
                .foregroundStyle(.secondary)
            Spacer()
            Text(appVersion)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v).\(b)"
    }
}

// MARK: - RoomRotationRuleView
//
// One protocol's room auto-update: how often (only what the protocol offers,
// with the note on how its rooms behave) and, for a schedule, when in the day.

struct RoomRotationRuleView: View {
    let carrier: String
    @ObservedObject private var settings = SettingsStore.shared

    /// The three kinds of window; a chosen hour carries its hour separately.
    private enum WindowKind: Hashable {
        case anyTime, night, hour
    }

    /// The hour a newly chosen "at a chosen hour" starts on: inside the night,
    /// the quietest time for most people.
    private static let firstChosenHour = 3

    var body: some View {
        Form {
            ruleSection
            if settings.roomRotationRule(for: carrier).hasWindow {
                windowSection
            }
        }
        .signalFormChrome()
        .navigationTitle(CarrierTransportMatrix.carrierLabel(carrier))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var options: [RoomRotationRule] { RoomRotationRule.allowed(for: carrier) }

    /// A protocol that offers only Off (MTS Link until the app can make a
    /// meeting) has nothing to pick, so its picker is disabled and the note
    /// says why.
    private var ruleSection: some View {
        Section {
            Picker(L10n.roomRotationHowOften.localized(), selection: ruleBinding) {
                ForEach(options) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(options.count < 2)
        } header: {
            SignalSectionHeader(L10n.roomRotationHowOften.localized())
        } footer: {
            Text(RoomRotationRule.noteKey(for: carrier).localized())
        }
        .signalFormRows()
    }

    private var windowSection: some View {
        Section {
            Picker(L10n.roomRotationWhen.localized(), selection: windowKindBinding) {
                Text(L10n.roomRotationWhenAny.localized()).tag(WindowKind.anyTime)
                Text(L10n.roomRotationWhenNight.localized()).tag(WindowKind.night)
                Text(L10n.roomRotationWhenHour.localized()).tag(WindowKind.hour)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let chosen = chosenHour {
                Picker(L10n.roomRotationHourLabel.localized(), selection: hourBinding(chosen)) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(RoomRotationWindow.hourLabel(h)).tag(h)
                    }
                }
            }
        } header: {
            SignalSectionHeader(L10n.roomRotationWhen.localized())
        } footer: {
            switch window {
            case .anyTime: EmptyView()
            case .night:   Text(L10n.roomRotationNightNote.localized())
            case .hour:    Text(L10n.roomRotationHourNote.localized())
            }
        }
        .signalFormRows()
    }

    private var window: RoomRotationWindow { settings.roomRotationWindow(for: carrier) }

    private var chosenHour: Int? {
        if case .hour(let h) = window { return h }
        return nil
    }

    private var ruleBinding: Binding<RoomRotationRule> {
        Binding(get: { settings.roomRotationRule(for: carrier) },
                set: { settings.setRoomRotationRule($0, for: carrier) })
    }

    private var windowKindBinding: Binding<WindowKind> {
        Binding(get: {
            switch window {
            case .anyTime: return .anyTime
            case .night:   return .night
            case .hour:    return .hour
            }
        }, set: { kind in
            switch kind {
            case .anyTime: settings.setRoomRotationWindow(.anyTime, for: carrier)
            case .night:   settings.setRoomRotationWindow(.night, for: carrier)
            case .hour:
                if chosenHour != nil { return }
                settings.setRoomRotationWindow(.hour(Self.firstChosenHour), for: carrier)
            }
        })
    }

    private func hourBinding(_ chosen: Int) -> Binding<Int> {
        Binding(get: { chosen },
                set: { settings.setRoomRotationWindow(RoomRotationWindow.clampedHour($0), for: carrier) })
    }
}

// MARK: - SettingsNumberField
//
// A TextField for direct entry of a whole number, its title above it;
// out-of-range values are clamped by `SettingsStore.didSet`. The screen that
// shows it owns the focus, so its keyboard's Done button can close it.

struct SettingsNumberField: View {
    let title: String
    @Binding var value: Int
    var unit: String? = nil
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("", value: $value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .focused(focus)
                    .accessibilityLabel(title)
                if let unit {
                    Text(unit).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }
}

// MARK: - SettingsAdvancedView
//
// The last row of the Settings list: the rare and technical. The directory
// groups the editors by what they act on — Connection (session timing and the
// checks while it runs, the early restart of a wedged core, the local proxy's
// port), Servers (how the app reaches them, this install's room name) and
// Diagnostics (check sources, log knobs). Every directory row shows its
// current value as one caption line in the same style.
//
// Each editor is a real observing view pushed with the same injected stores, so
// bindings write to the store that the visible rows read.

struct SettingsAdvancedView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// The port check compares against the port the session actually bound.
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore

    enum Page: Equatable {
        case directory, connection, proxy, diagnostics, logs

        var titleKey: L10n {
            switch self {
            case .directory: return .settingsAdvancedRow
            case .connection: return .settingsSectionConnection
            case .proxy: return .settingsSectionProxy
            case .diagnostics: return .diagnosticsTitle
            case .logs: return .sectionLogs
            }
        }
    }

    let page: Page

    init(tunnel: TunnelManager, serverStore: ServerHostStore,
         connections: ConnectionStore, page: Page = .directory) {
        self.tunnel = tunnel
        self.serverStore = serverStore
        self.connections = connections
        self.page = page
    }

    @State private var portCheck: PortAvailability.PortState?
    /// This install's room name (DeviceIdentity); re-rolled by the button.
    @State private var deviceName: String = DeviceIdentity.current()
    @FocusState private var anyFieldFocused: Bool

    var body: some View {
        advancedWiring(advancedChrome(advancedForm))
    }

    private var advancedForm: some View {
        Form {
            if page == .directory {
                directorySections
            } else {
                editorSection
            }
        }
    }

    // MARK: Directory

    @ViewBuilder
    private var directorySections: some View {
        Section {
            pageLink(.connection, systemImage: "timer", subtitle: connectionSummary)
            pageLink(.proxy, systemImage: "network", subtitle: proxySummary)
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized())
        }
        .signalFormRows()

        Section {
            Picker(L10n.serverControlLabel.localized(), selection: $settings.serverControl) {
                ForEach(ServerControl.allCases) { control in
                    Text(control.title).tag(control)
                }
            }
            TunnelSettingsNote(text: settings.serverControl.hint)
        } header: {
            SignalSectionHeader(L10n.serversTitle.localized())
        }
        .signalFormRows()

        Section {
            HStack(spacing: Theme.Metrics.s2) {
                SignalSettingsLabel(L10n.deviceNameLabel.localized(),
                                    subtitle: deviceName, systemImage: "person.crop.circle.dashed")
                Spacer(minLength: 0)
                Button(L10n.deviceNameRegenerate.localized()) {
                    deviceName = DeviceIdentity.regenerate()
                }
                .buttonStyle(.borderless)
                .font(Theme.Typography.caption)
            }
        } header: {
            SignalSectionHeader(L10n.deviceNameSectionHeader.localized())
        } footer: {
            Text(L10n.deviceNameFooter.localized())
        }
        .signalFormRows()

        Section {
            pageLink(.diagnostics, systemImage: "waveform.path.ecg", subtitle: diagnosticsSummary)
            pageLink(.logs, systemImage: "doc.text", subtitle: settings.logLevel.label)
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized())
        }
        .signalFormRows()
    }

    private func pageLink(_ target: Page, systemImage: String, subtitle: String) -> some View {
        NavigationLink {
            SettingsAdvancedView(tunnel: tunnel, serverStore: serverStore,
                                 connections: connections, page: target)
        } label: {
            SignalSettingsLabel(target.titleKey.localized(), subtitle: subtitle, systemImage: systemImage)
        }
    }

    // Current values, one caption each.

    private var connectionSummary: String {
        L10n.settingsConnectionSummary_fmt.formatted(settings.startTimeoutSeconds, settings.keepAliveSeconds)
    }

    private var proxySummary: String {
        Self.proxyAddress(boundPort: tunnel.boundPort, configuredPort: settings.socksPort)
    }

    private var diagnosticsSummary: String {
        let provider = Self.providerName(AppConstants.SpeedTest.provider(id: settings.speedTestProviderID))
        return L10n.settingsDiagnosticsSummary_fmt.formatted(provider, settings.enabledIPSources.count)
    }

    // MARK: Editors

    @ViewBuilder
    private var editorSection: some View {
        switch page {
        case .directory: EmptyView()
        case .connection: connectionSection
        case .proxy: proxySection
        case .diagnostics: diagnosticsSection
        case .logs: logsSection
        }
    }

    private func advancedChrome(_ content: some View) -> some View {
        content
            .signalFormChrome()
    }

    private func advancedWiring(_ content: some View) -> some View {
        content
            .navigationTitle(page.titleKey.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page != .directory {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L10n.done.localized()) { anyFieldFocused = false }
                    }
                }
            }
    }

    // MARK: Connection

    /// The values that TIME a session: how long to wait for it to come up, how
    /// often to prove it still passes traffic, and the opt-in early restart.
    private var connectionSection: some View {
        Section {
            numericField(L10n.startTimeoutLabel.localized(), value: $settings.startTimeoutSeconds,
                         unit: L10n.unitSeconds.localized(),
                         note: L10n.startTimeoutNote.localized())
            numericField(L10n.tunnelCheckLabel.localized(), value: $settings.keepAliveSeconds,
                         unit: L10n.unitSeconds.localized(),
                         note: L10n.footerKeepAlive.localized())
            Toggle(L10n.earlyRestartWedgeLabel.localized(), isOn: $settings.earlyRestartOnWedge)
            TunnelSettingsNote(text: L10n.earlyRestartWedgeNote.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized())
        }
        .signalFormRows()
    }

    // MARK: Proxy

    @ViewBuilder
    private var proxySection: some View {
        Section {
            portRow
            proxyAddressRow
            TunnelSettingsNote(text: L10n.socksPortChangeNote.localized())
            Button { runPortCheck() } label: { portCheckLabel }
        } header: {
            SignalSectionHeader(L10n.settingsSectionProxy.localized())
        }
        .signalFormRows()
        // The verdict describes the port that was CHECKED; a new value is unchecked.
        .onChange(of: settings.socksPort) { _, _ in portCheck = nil }
    }

    /// Host AND port, as one selectable line — what goes into another app's
    /// proxy settings. A local address that only answers in proxy mode.
    private var proxyAddressRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(L10n.settingsProxyAddressLabel.localized())
            Text(Self.proxyAddress(boundPort: tunnel.boundPort, configuredPort: settings.socksPort))
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
        }
    }

    /// The live listener is authoritative; configuration is only a fallback.
    nonisolated static func proxyAddress(boundPort: Int?, configuredPort: Int) -> String {
        "127.0.0.1:\(boundPort ?? configuredPort)"
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(L10n.settingsPortLabel.localized())
            HStack {
                TextField("8808", value: $settings.socksPort, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .focused($anyFieldFocused)
                    .monospacedDigit()
                    .accessibilityLabel(L10n.settingsPortLabel.localized())
                Button(L10n.randomPortAction.localized()) {
                    settings.socksPort = Int.random(in: 1024...65535)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var portCheckLabel: some View {
        HStack {
            Image(systemName: "checkmark.circle")
            Text(L10n.checkPortAction.localized())
            Spacer()
            if let r = portCheck {
                switch r {
                case .free:      Text(L10n.portFree.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOurs:  Text(L10n.portInUseByOlcrtc.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOther: Text(L10n.portBusy.localized()).foregroundStyle(Theme.Palette.red)
                }
            }
        }
    }

    private func runPortCheck() {
        let port = UInt16(settings.socksPort)
        // Compare against the port the tunnel actually bound (`tunnel.boundPort`,
        // snapshotted at connect; nil unless a session is live).
        let tunnelHoldsPort = tunnel.boundPort == settings.socksPort
        let result = PortAvailability.state(port, tunnelHoldsPort: tunnelHoldsPort)
        portCheck = result
        let logLine: String
        switch result {
        case .free:      logLine = L10n.logPortFree_fmt.formatted(settings.socksPort)
        case .busyOther: logLine = L10n.logPortBusyOther_fmt.formatted(settings.socksPort)
        case .busyOurs:  logLine = L10n.logPortBusyOlcrtc_fmt.formatted(settings.socksPort)
        }
        LogStore.shared.log(.connection, logLine)
    }

    // MARK: Numeric field helper

    /// A TextField for direct entry; out-of-range values are clamped by
    /// `SettingsStore.didSet`. The note, when given, renders directly under it.
    @ViewBuilder
    private func numericField(_ title: String,
                              value: Binding<Int>,
                              unit: String? = nil,
                              note: String? = nil) -> some View {
        SettingsNumberField(title: title, value: value, unit: unit, focus: $anyFieldFocused)
        if let note {
            TunnelSettingsNote(text: note)
        }
    }

    // MARK: Diagnostics

    /// WHICH service answers a check — a fallback for a blocked network.
    private var diagnosticsSection: some View {
        Section {
            ipSourcesRow
            Picker(L10n.sectionSpeedProvider.localized(), selection: $settings.speedTestProviderID) {
                ForEach(AppConstants.SpeedTest.providers) { p in
                    Text(Self.providerName(p)).tag(p.id)
                }
            }
            // The name identifies the provider; the host is data on its own line.
            Text(speedProviderHost)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized())
        } footer: {
            Text(L10n.speedProviderFooter.localized())
        }
        .signalFormRows()
    }

    private var ipSourcesRow: some View {
        NavigationLink {
            IPSourcesSettingsView()
        } label: {
            HStack {
                SignalSettingsLabel(L10n.sectionIPSources.localized(), systemImage: "network")
                Spacer()
                Text("\(settings.enabledIPSources.count)")
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var speedProviderHost: String {
        AppConstants.SpeedTest.provider(id: settings.speedTestProviderID).host
    }

    /// Display name for a speed-test provider: the brand in parentheses when
    /// the label carries one ("proof.ovh.net (OVH)"), else the host's
    /// registrable label ("speed.cloudflare.com" → "Cloudflare").
    private static func providerName(_ p: SpeedTestProvider) -> String {
        if let open = p.label.firstIndex(of: "("),
           let close = p.label.lastIndex(of: ")"), open < close {
            let inside = p.label[p.label.index(after: open)..<close]
            let trimmed = inside.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        let parts = p.host.split(separator: ".")
        guard parts.count >= 2 else { return p.host }
        let name = String(parts[parts.count - 2])
        return name.prefix(1).uppercased() + String(name.dropFirst())
    }

    // MARK: Logs

    /// The knobs that shape the log; reading it is on the main list.
    private var logsSection: some View {
        Section {
            Picker(L10n.logLevelLabel.localized(), selection: $settings.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            TunnelSettingsNote(text: L10n.logLevelNote.localized())
            numericField(L10n.logBufferLabel.localized(), value: $settings.logBufferSize,
                         note: L10n.footerLogBuffer.localized())
            numericField(L10n.containerLogsTailLabel.localized(), value: $settings.containerLogsTailLines,
                         note: L10n.containerLogsTailNote.localized())
            Button(L10n.clearAllLogsAction.localized(), role: .destructive) {
                LogStore.shared.clearAll()
                // The clear is instant and its effect is off-screen — confirm it fired.
                Haptics.success()
            }
        } header: {
            SignalSectionHeader(L10n.sectionLogs.localized())
        }
        .signalFormRows()
    }
}

// MARK: - CarrierEndpointsPickerView
//
// The Settings entrance to the bypass list for another proxy app. The addresses
// derive from a connection's room, so this screen lists the connections and
// opens `CarrierEndpointsView` for the chosen one.

struct CarrierEndpointsPickerView: View {
    @ObservedObject var connections: ConnectionStore
    @State private var chosen: ConnectionRecord?

    var body: some View {
        Form {
            Section {
                // Carrier endpoints derive from an olcrtc room; an Xray record has
                // no carrier, so the picker lists olcrtc connections only.
                let eligible = connections.connections.filter { $0.details.isOlcrtc }
                if eligible.isEmpty {
                    Text(L10n.settingsCarrierEndpointsEmpty.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ForEach(eligible) { conn in
                        Button { chosen = conn } label: {
                            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                                Text(conn.displayName)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(conn.details.subtitle)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                    }
                }
            } footer: {
                Text(L10n.carrierEndpointsLead.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.carrierEndpointsScreenTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chosen) { conn in
            switch conn.details {
            case .olcrtc(let params):
                CarrierEndpointsView(params: params)
            case .xray:
                // Carrier endpoints are an olcrtc concept; the picker that
                // feeds `chosen` only lists olcrtc records (see `isOlcrtc`).
                EmptyView()
            }
        }
    }
}

// MARK: - IPSourcesSettingsView
//
// The IP-check source checkboxes. The model, default subset and empty-set
// fallback live in SettingsStore.

struct IPSourcesSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(AppConstants.ipCheckServices, id: \.label) { svc in
                    Toggle(isOn: Binding(
                        get: { settings.enabledIPSources.contains(svc.label) },
                        set: { on in
                            if on { settings.enabledIPSources.insert(svc.label) }
                            else  { settings.enabledIPSources.remove(svc.label) }
                        }
                    )) {
                        Text(svc.label)
                    }
                }
            } header: {
                SignalSectionHeader(L10n.sectionIPSources.localized())
            } footer: {
                Text(L10n.ipSourcesFooter.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.sectionIPSources.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - DNSSettingsView
//
// DNS presets as rows (name + address + checkmark) plus the free-form field.

struct DNSSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var fieldFocused: Bool

    /// The free-form field edits a DRAFT; only a valid `host:port` reaches the
    /// store. The Go core's `SetDNS` rejects anything else, and the same string
    /// is baked into a new server's `dns:` line.
    @State private var dnsDraft: String = SettingsStore.shared.dnsServer

    private var dnsDraftBinding: Binding<String> {
        Binding(get: { dnsDraft }, set: { value in
            dnsDraft = value
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidResolver(trimmed) { settings.dnsServer = trimmed }
        })
    }

    private var draftIsValid: Bool {
        Self.isValidResolver(dnsDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// PURE: the Go runtime's rule (net.SplitHostPort, non-empty host, port
    /// 1…65535), so the field refuses exactly what the core would refuse.
    /// Tested in Tests/Review470Chunk5Tests.swift.
    static func isValidResolver(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":") else { return false }
        var host = String(value[..<colon])
        let portText = String(value[value.index(after: colon)...])
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            host = String(host.dropFirst().dropLast())
        } else if host.contains(":") {
            return false   // an unbracketed IPv6 literal — "too many colons" to SplitHostPort
        }
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let port = Int(portText), (1...65535).contains(port) else { return false }
        return true
    }

    /// Global presets + RU-carrier presets (labels localized). Keyed by label
    /// — values are NOT unique (Yota shares MegaFon's resolver).
    private var presets: [(label: String, value: String)] {
        AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(presets, id: \.label) { preset in
                    Button {
                        settings.dnsServer = preset.value
                        dnsDraft = preset.value
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                                Text(preset.label)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(preset.value)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            if settings.dnsServer == preset.value {
                                Image(systemName: "checkmark")
                                    .font(Theme.Typography.captionStrong)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(settings.dnsServer == preset.value ? .isSelected : [])
                }
            } header: {
                SignalSectionHeader(L10n.sectionDNS.localized())
            } footer: {
                Text(L10n.dnsFooter.localized())
            }
            .signalFormRows()

            Section {
                TextField(L10n.dnsFreeFormPlaceholder.localized(), text: dnsDraftBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.Typography.body.monospaced())
                    .focused($fieldFocused)
                    .accessibilityLabel(L10n.sectionDNS.localized())
                if !draftIsValid {
                    Text(L10n.dnsInvalidNote.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.red)
                }
            } header: {
                SignalSectionHeader(L10n.dnsFreeFormPlaceholder.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.sectionDNS.localized())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.done.localized()) { fieldFocused = false }
            }
        }
    }
}

#if DEBUG
#Preview("Settings — Dark") {
    SettingsView(tunnel: TunnelManager(),
                 serverStore: ServerHostStore(), connections: ConnectionStore())
        .preferredColorScheme(.dark)
}
#Preview("Settings — Light") {
    SettingsView(tunnel: TunnelManager(),
                 serverStore: ServerHostStore(), connections: ConnectionStore())
        .preferredColorScheme(.light)
}
#Preview("Settings — Advanced") {
    NavigationStack {
        SettingsAdvancedView(tunnel: TunnelManager(),
                             serverStore: ServerHostStore(), connections: ConnectionStore())
    }
    .preferredColorScheme(.dark)
}
#endif
