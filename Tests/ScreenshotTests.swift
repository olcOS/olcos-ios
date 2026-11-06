import XCTest
import SwiftUI
@testable import olcrtc_ios

// Renders the main screens to PNG so the interface can be reviewed without a
// phone: Russian, light and dark, at the simulator's own size and at 375×667.
// CI uploads `build/screens` next to the IPA. Nothing here dials a network:
// the hero and the rows take value inputs, the connection list runs on a
// private defaults suite with automatic checks off, and every verdict, key
// and setting the test touches is restored.

@MainActor
final class ScreenshotTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/screens", isDirectory: true)

    private let suiteName = "olcos.screenshots"
    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?
    private var savedLanguage = ""
    private var savedRefreshOnEntry = true
    private var savedTunnel: TunnelManager?
    private var savedStore: ConnectionStore?
    private var createdIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        savedRefreshOnEntry = SettingsStore.shared.refreshOnEntry
        SettingsStore.shared.language = "ru"
        SettingsStore.shared.refreshOnEntry = false
        HealthCoordinator.flushPendingWrites()
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)
        HealthCoordinator.shared._resetForTesting()
        savedTunnel = TunnelManager.shared
        savedStore = ConnectionStore.shared
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in createdIDs { ConnectionSecretStore.remove(connectionID: id) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let healthSnapshot { UserDefaults.standard.set(healthSnapshot, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        SettingsStore.shared.language = savedLanguage
        SettingsStore.shared.refreshOnEntry = savedRefreshOnEntry
        SettingsStore.flushPendingWrites()
        TunnelManager.shared = savedTunnel
        ConnectionStore.shared = savedStore
        super.tearDown()
    }

    // MARK: Screens

    func testHeroStates() async throws {
        let (telemost, _, xray) = Self.records()
        try await capture("hero-idle") {
            Self.page { Self.hero(state: .disconnected, subject: telemost, health: .verified(ms: 140, age: 40)) }
        }
        try await capture("hero-connecting") {
            Self.page { Self.hero(state: .connecting, subject: xray, health: .never) }
        }
        try await capture("hero-connected") {
            Self.page {
                Self.hero(state: .connected, subject: xray, health: .verified(ms: 72, age: 8), isBest: true,
                          throughput: .exact(inBytesPerSecond: 2_400_000, outBytesPerSecond: 310_000),
                          intensity: 0.7)
            }
        }
        try await capture("hero-failed") {
            Self.page {
                Self.hero(state: .failed(L10n.tunnelStalls.localized()), subject: xray,
                          health: .handshakeOnly(age: 20))
            }
        }
    }

    func testLanePanel() async throws {
        let (_, _, xray) = Self.records()
        let lanes = [
            LaneReading(id: 0, name: "Jitsi", inBytesPerSecond: 516_000, outBytesPerSecond: 15_000),
            LaneReading(id: 1, name: "Jitsi 2", inBytesPerSecond: 509_000, outBytesPerSecond: 14_000),
            LaneReading(id: 2, name: "SaluteJazz", inBytesPerSecond: 301_000, outBytesPerSecond: 9_000),
            LaneReading(id: 3, name: "Яндекс Телемост", inBytesPerSecond: 0, outBytesPerSecond: 0),
        ]
        try await capture("home-lanes") {
            Self.page {
                VStack(spacing: Theme.Metrics.s4) {
                    Self.hero(state: .connected, subject: xray, health: .verified(ms: 95, age: 8),
                              throughput: .exact(inBytesPerSecond: 1_326_000, outBytesPerSecond: 38_000),
                              intensity: 0.8)
                    LaneTrafficPanel(lanes: lanes)
                }
            }
        }
    }

    func testLiveActivityCard() async throws {
        let state = TunnelActivityAttributes.ContentState(
            phase: "on", headline: L10n.stateConnected.localized(), detail: "Весь сервер · ams-1",
            since: Date().addingTimeInterval(-3_725),
            down: ThroughputFormat.bits(1_326_000), up: ThroughputFormat.bits(38_000),
            downShort: ThroughputFormat.bitsShort(1_326_000),
            history: [120_000, 300_000, 560_000, 900_000, 1_100_000, 980_000, 1_250_000, 1_326_000,
                      1_200_000, 1_400_000, 1_310_000, 1_326_000])
        try await capture("live-activity") {
            Self.page {
                TunnelActivityCard(state: state)
                    .padding(Theme.Metrics.s4)
                    .background(Theme.Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.top, Theme.Metrics.s8)
            }
        }
    }

    func testProtocolCheck() async throws {
        let check = ProtocolSpeedCheck()
        typealias Row = ProtocolSpeedCheck.Row
        check._showForTesting([
            Row(id: 0, name: "Jitsi", phase: .done, pingMs: 92, bytesPerSecond: 516_000,
                exit: "🇳🇱 Amsterdam, NL"),
            Row(id: 1, name: "Jitsi 2", phase: .done, pingMs: 88, bytesPerSecond: 565_000,
                exit: "🇳🇱 Amsterdam, NL"),
            Row(id: 2, name: "SaluteJazz", phase: .failed),
            Row(id: 3, name: "Яндекс Телемост", phase: .measuring,
                samples: [0, 40_000, 120_000, 210_000, 180_000, 260_000, 240_000, 300_000]),
            Row(id: ProtocolSpeedCheck.allTogether, name: "", phase: .waiting),
        ])
        try await capture("diagnostics-protocols") {
            Self.page { ProtocolCheckCard(check: check, onRunAll: {}, onRunOne: { _ in }) }
        }
    }

    func testConnectionRows() async throws {
        let (telemost, jitsi, xray) = Self.records()
        let rows: [(ConnectionRecord, HealthDisplay, Bool)] = [
            (xray, .verified(ms: 72, age: 30), true),
            (telemost, .verified(ms: 140, age: 90), false),
            (jitsi, .broken(.noPeer, age: 300), false),
            (telemost, .handshakeOnly(age: 120), false),
            (jitsi, .inconclusive(.hostUnreachable, age: 600), false),
            (xray, .checking, false),
            (telemost, .never, false),
        ]
        try await capture("rows") {
            List {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        ConnectionListRow(title: ConnectionNaming.listTitle(row.0),
                                          subtitle: ConnectionNaming.listSubtitle(row.0),
                                          display: row.1, isSelected: index == 1, isLive: false,
                                          isBest: row.2, menuItems: [], onTap: {}, onVerify: {})
                    }
                }
                .signalFormRows()
            }
            .signalFormChrome()
        }
    }

    func testServersTab() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults)
        let servers = ServerHostStore(defaults: defaults)
        let (bundle, protocols) = try Self.wholeServer()
        var host = ServerHost(label: "ams-1", host: "203.0.113.7")
        host.bundleConnectionID = bundle.id
        host.lastConnectionID = protocols[0].id
        host.extraConnectionIDs = protocols.dropFirst().map(\.id)
        servers.hosts.append(host)
        let (telemost, jitsi, xray) = Self.records()
        var nl = xray
        nl.name = "🇳🇱 Нидерланды"
        for record in [bundle] + protocols + [telemost, jitsi, nl] {
            store.add(record)
            createdIDs.append(record.id)
        }
        store.setPrimary(bundle.id)
        HealthCoordinator.shared.noteLiveVerified(recordID: bundle.id, rttMs: 95)
        HealthCoordinator.shared.noteLiveVerified(recordID: nl.id, rttMs: 72)
        HealthCoordinator.shared.noteFailure(recordID: jitsi.id, raw: "no peer in room",
                                             source: "probe", classified: .noPeer)
        let lists = importLists(into: store)
        let tunnel = TunnelManager(engine: LifecycleEngine(), runtimeEffectsEnabled: false, verify: { true })
        try await capture("servers-tab") {
            ConnectionListView(store: store, tunnel: tunnel, serverStore: servers,
                               addServerPending: .constant(false), onImportText: { _ in })
        }
        try await capture("subscription-detail") {
            NavigationStack {
                SubscriptionDetailView(source: lists.white, store: store, tunnel: tunnel,
                                       menuItems: { _ in [] }, onConnect: { _ in })
            }
        }
    }

    /// Two subscriptions: a white list with its servers checked, and a
    /// switched-off one nobody checked.
    private func importLists(into store: ConnectionStore) -> (white: String, black: String) {
        let white = "https://lists.example.org/white"
        let black = "https://lists.example.org/black"
        func vless(_ host: String, _ name: String) -> String {
            "vless://adc11f30-e4cb-4985-bf5e-f9ded69c019f@\(host):443?encryption=none&flow=xtls-rprx-vision"
                + "&security=reality&sni=eh.vk.ru&pbk=fNfokzklCF4l_c8k8PciOCjm5ecNoF_sNLjEtaO-xzI"
                + "&sid=db04ce8bdb8900f1&type=tcp#\(name)"
        }
        let moscow = "%F0%9F%87%B7%F0%9F%87%BA%20%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0"
        let spb = "%F0%9F%87%B7%F0%9F%87%BA%20%D0%A1%D0%B0%D0%BD%D0%BA%D1%82-%D0%9F%D0%B5%D1%82%D0%B5%D1%80%D0%B1%D1%83%D1%80%D0%B3"
        let helsinki = "%F0%9F%87%AB%F0%9F%87%AE%20%D0%A5%D0%B5%D0%BB%D1%8C%D1%81%D0%B8%D0%BD%D0%BA%D0%B8"
        let frankfurt = "%F0%9F%87%A9%F0%9F%87%AA%20%D0%A4%D1%80%D0%B0%D0%BD%D0%BA%D1%84%D1%83%D1%80%D1%82"
        store.importSubscription(OlcrtcSubscription.parse("""
            #name: Белые списки (мобильные)
            #refresh: 1h
            \(vless("203.0.113.21", moscow))
            \(vless("203.0.113.22", spb))
            \(vless("203.0.113.23", helsinki))
            """), source: white)
        store.importSubscription(OlcrtcSubscription.parse("""
            #name: Чёрный список
            \(vless("203.0.113.31", frankfurt))
            """), source: black)
        store.setSubscription(black, enabled: false)
        createdIDs += store.connections.map(\.id)
        let checked = store.records(ofSubscription: white)
        if checked.count == 3 {
            HealthCoordinator.shared.noteLiveVerified(recordID: checked[0].id, rttMs: 48)
            HealthCoordinator.shared.noteLiveVerified(recordID: checked[1].id, rttMs: 61)
            HealthCoordinator.shared.noteFailure(recordID: checked[2].id, raw: "handshake timeout",
                                                 source: "probe", classified: .timedOut)
        }
        return (white, black)
    }

    func testConnectionsScreen() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults)
        let (telemost, jitsi, xray) = Self.records()
        for record in [telemost, jitsi, xray] {
            store.add(record)
            createdIDs.append(record.id)
        }
        store.setPrimary(telemost.id)
        HealthCoordinator.shared.noteLiveVerified(recordID: xray.id, rttMs: 72)
        HealthCoordinator.shared.noteLiveVerified(recordID: telemost.id, rttMs: 140)
        HealthCoordinator.shared.noteFailure(recordID: jitsi.id, raw: "no peer in room",
                                             source: "probe", classified: .noPeer)
        let tunnel = TunnelManager(engine: LifecycleEngine(), runtimeEffectsEnabled: false, verify: { true })
        try await capture("connections") {
            ConnectionsView(store: store, tunnel: tunnel, ipCheck: IPChecker(), speed: SpeedTest())
        }
    }

    func testSettingsScreen() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tunnel = TunnelManager(engine: LifecycleEngine(), runtimeEffectsEnabled: false, verify: { true })
        let connections = ConnectionStore(defaults: defaults)
        let servers = ServerHostStore(defaults: defaults)
        try await capture("settings") {
            SettingsView(tunnel: tunnel, serverStore: servers,
                         connections: connections)
        }
    }

    func testServerCards() async throws {
        try await capture("server-card") {
            ScrollView {
                VStack(spacing: Theme.Metrics.s4) {
                    Self.serverCard(headline: .health(.verified(ms: 72, age: 60),
                                                      tally: ProtocolsTally(working: 2, total: 3,
                                                                            failed: ["Yandex Telemost"])),
                                    progress: nil, primary: .check)
                    Self.serverCard(headline: .busy(verb: HostOp.install.verb,
                                                    note: "podman build olcrtc", step: 2,
                                                    of: HostOp.install.stepCount),
                                    progress: 0.4, primary: .busy)
                }
                .padding(Theme.Metrics.s4)
            }
            .background(Theme.Palette.bg)
        }
    }

    func testAddServerWizard() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let servers = ServerHostStore(defaults: defaults)
        let connections = ConnectionStore(defaults: defaults)
        let flow = AddServerFlowController(otherLabels: [])
        try await capture("wizard-1-access") {
            Self.wizardPage(.access) { AddServerAccessStep(flow: flow) }
        }
        flow.plan.selected = ["telemost", "jitsi"]
        flow.plan.xray = true
        flow.step = .protocols
        try await capture("wizard-3-protocols") {
            Self.wizardPage(.protocols) { AddServerProtocolsStep(flow: flow) }
        }
        flow.step = .room
        flow.jitsi = .picked(host: "meet.egovm.ru")
        try await capture("wizard-4-room") {
            Self.wizardPage(.room) { AddServerRoomStep(flow: flow, yandexStore: flow.yandexStore) }
        }
        flow.plan.selected = ["vkcalls", "salutejazz"]
        flow.rooms.vkLink = "Присоединяйтесь: https://vk.com/call/join/AbCdEf123"
        flow.rooms.saluteRoom = "vo0me7:q1w2e3r4"
        flow.salute = .created
        try await capture("wizard-4-room-vk-salute") {
            Self.wizardPage(.room) { AddServerRoomStep(flow: flow, yandexStore: flow.yandexStore) }
        }
        flow.plan.selected = ["telemost", "jitsi"]
        flow.step = .install
        flow.access.label = "ams-1"
        flow.access.host = "203.0.113.7"
        try await capture("wizard-5-install") {
            Self.wizardPage(.install) {
                AddServerInstallStep(flow: flow, serverStore: servers, connections: connections)
            }
        }
    }

    func testFirstRun() async throws {
        try await capture("welcome") {
            WelcomeView(onImportText: { _ in }, onAddServer: {}, onManual: {})
        }
        try await capture("service-accounts") {
            NavigationStack { ServiceAccountsView() }
        }
    }

    func testWholeServer() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ConnectionStore(defaults: defaults)
        let (bundle, protocols) = try Self.wholeServer()
        for record in [bundle] + protocols + [Self.records().2] {
            store.add(record)
            createdIDs.append(record.id)
        }
        store.setPrimary(bundle.id)
        HealthCoordinator.shared.noteLiveVerified(recordID: bundle.id, rttMs: 95)
        let tunnel = TunnelManager(engine: LifecycleEngine(), runtimeEffectsEnabled: false, verify: { true })
        try await capture("whole-server-connect") {
            ConnectionsView(store: store, tunnel: tunnel, ipCheck: IPChecker(), speed: SpeedTest())
        }
        try await capture("whole-server-hero-connected") {
            Self.page {
                Self.hero(state: .connected, subject: bundle, health: .verified(ms: 95, age: 8),
                          throughput: .exact(inBytesPerSecond: 1_900_000, outBytesPerSecond: 240_000),
                          intensity: 0.6)
            }
        }
        let row = ProtocolRowView(
            title: L10n.bundleServiceName.localized(),
            transport: "",
            isLive: true, isRunningOnServer: true, health: .verified(ms: 95, age: 8),
            menuDisabled: false, menuItems: [], detailLines: [L10n.bundleCardDesc.localized()],
            isBest: true, roomCount: 4, stateNote: L10n.bundleBonded.localized(),
            onVerify: {}, onConnect: {})
        try await capture("whole-server-card") {
            ScrollView {
                Self.serverCard(headline: .health(.verified(ms: 95, age: 60),
                                                  tally: ProtocolsTally(working: 3, total: 3)),
                                progress: nil, primary: .stop,
                                leading: [ServerServiceRow(id: "bundle", view: row)])
                    .padding(Theme.Metrics.s4)
            }
            .background(Theme.Palette.bg)
        }
    }

    func testDeviceInvites() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let servers = ServerHostStore(defaults: defaults)
        let connections = ConnectionStore(defaults: defaults)
        var host = ServerHost(label: "ams-1", host: "203.0.113.7")
        var tablet = DeviceInvite(name: "iPad")
        tablet.publishedAt = Date().addingTimeInterval(-600)
        host.invites = [tablet, DeviceInvite(name: "Телефон мамы")]
        host.sharePort = 38471
        servers.hosts.append(host)
        // No linked connection, so nothing is ever uploaded from here.
        let sync = InviteSync(connections: connections, hosts: servers)
        try await capture("devices") {
            NavigationStack { DeviceInvitesView(hostID: host.id, hosts: servers, sync: sync) }
        }
        // What the agent's usage adds: the iPad's invite went to two installs,
        // one of them connected now; mum's phone was last connected 26 hours
        // ago; a third invite was never used.
        let laptop = DeviceInvite(name: "Ноутбук")
        servers.hosts[servers.hosts.count - 1].invites = (host.invites ?? []) + [laptop]
        let mum = try XCTUnwrap(host.invites?.last)
        let now = Int64(Date().timeIntervalSince1970)
        let usage = AgentUsage(at: now, devices: [
            .init(id: tablet.clientID + "-quiet-harbor-42", lastSeen: now - 20, online: true,
                  bytesIn: 85_000_000, bytesOut: 1_200_000_000, sessions: 14),
            .init(id: tablet.clientID + "-amber-lark-17", lastSeen: now - 7_200, online: false,
                  bytesIn: 3_100_000, bytesOut: 240_000_000, sessions: 3),
            .init(id: mum.clientID + "-calm-river-31", lastSeen: now - 26 * 3_600, online: false,
                  bytesIn: 12_400_000, bytesOut: 410_000_000, sessions: 5),
            .init(id: "quiet-orbit-77", lastSeen: now - 60, online: true,
                  bytesIn: 1, bytesOut: 1, sessions: 1),
        ])
        try await capture("devices-usage") {
            NavigationStack {
                DeviceInvitesView(hostID: host.id, hosts: servers, sync: sync, fixedUsage: usage)
            }
        }
        let link = InviteLink.encode(host: "203.0.113.7", port: 38471, token: tablet.token,
                                     key: InviteLink.makeKey())
        try await capture("device-invite-link") {
            InviteLinkSheet(name: "iPad", link: link)
        }
    }

    // MARK: Fixtures

    private static func serverCard(headline: HostHeadline, progress: Double?,
                                   primary: ServerPrimaryAction,
                                   leading: [ServerServiceRow] = []) -> ServerCardView {
        let rows = [
            SSHRunner.CarrierInfo(file: "server.yaml", provider: "telemost", transport: "vp8channel",
                                  room: "90465372891949", container: "olcrtc-server-ywb3928e",
                                  status: .running("Up 2 hours"), isPrimary: true),
            SSHRunner.CarrierInfo(file: "server-jitsi.yaml", provider: "jitsi", transport: "datachannel",
                                  room: "olcos-room", container: "olcrtc-server-ywb3928e-jitsi",
                                  status: .stopped("Exited (1) 5 minutes ago"), isPrimary: false),
        ]
        let xray = ProtocolRowView(title: L10n.xrayServiceName.localized(), transport: "",
                                   isLive: false, isRunningOnServer: true,
                                   health: .verified(ms: 72, age: 30), menuDisabled: false, menuItems: [],
                                   isBest: true, onVerify: {}, onConnect: {})
        return ServerCardView(
            name: "ams-1", headline: headline, progress: progress, rows: rows, rowsBusy: false,
            listing: .loaded, canAddProtocol: true, actionsDisabled: primary == .busy, primary: primary,
            canOpenLogs: true, menuItems: [], onPrimary: {}, onAddProtocol: {}, onLogs: {}, onManage: {},
            row: { info in
                let running: Bool
                if case .running = info.status { running = true } else { running = false }
                return ProtocolRowView(title: CarrierTransportMatrix.carrierLabel(info.provider),
                                       transport: "",
                                       isLive: info.isPrimary, isRunningOnServer: running,
                                       health: info.isPrimary ? .verified(ms: 140, age: 60) : .broken(.noPeer, age: 300),
                                       menuDisabled: false, menuItems: [],
                                       roomCount: info.isPrimary ? 1 : 3,
                                       onVerify: {}, onConnect: {})
            },
            services: [ServerServiceRow(id: "olcos-xray-abc", view: xray)],
            leading: leading)
    }

    /// A server running Telemost (two rooms), VK Calls and SaluteJazz, its
    /// whole-server connection first.
    private static func wholeServer() throws -> (ConnectionRecord, [ConnectionRecord]) {
        let key = String(repeating: "ab", count: 32)
        func proto(_ carrier: String, _ transport: String, _ room: String) -> OlcrtcConnection {
            OlcrtcConnection(carrier: carrier, transport: transport, roomID: room, key: key, clientID: "default")
        }
        var telemost = proto("telemost", "vp8channel", "90465372891949")
        telemost.extraRooms = ["90465372891950"]
        let vk = proto("vkcalls", "vp8channel", "https://vk.com/call/join/AbCdEf123")
        let salute = proto("salutejazz", "datachannel", "vo0me7:q1w2e3r4")
        let params = try XCTUnwrap(ServerBundle.params(protocols: [telemost, vk, salute],
                                                       bond: "203.0.113.7:34567"))
        return (ConnectionRecord(name: "ams-1", details: .olcrtc(params)),
                [ConnectionRecord(name: "ams-1 · telemost", details: .olcrtc(telemost)),
                 ConnectionRecord(name: "ams-1 · vkcalls", details: .olcrtc(vk)),
                 ConnectionRecord(name: "ams-1 · salutejazz", details: .olcrtc(salute))])
    }

    /// A wizard step with the indicator and title the wizard draws around it.
    private static func wizardPage<Step: View>(_ step: AddServerStep,
                                               @ViewBuilder _ content: () -> Step) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                AddServerStepIndicator(current: step)
                    .padding(.horizontal, Theme.Metrics.cardPadding)
                    .padding(.vertical, Theme.Metrics.s3)
                ScrollView {
                    content()
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                        .padding(.bottom, Theme.Metrics.s8)
                }
            }
            .background(Theme.Palette.bg)
            .navigationTitle(step.title.localized())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static func records() -> (ConnectionRecord, ConnectionRecord, ConnectionRecord) {
        let key = String(repeating: "ab", count: 32)
        let telemost = ConnectionRecord(name: "ams-1", details: .olcrtc(OlcrtcConnection(
            carrier: "telemost", transport: "vp8channel", roomID: "90465372891949",
            key: key, clientID: "default")))
        let jitsi = ConnectionRecord(name: "ams-1", details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: "olcos-room",
            key: key, clientID: "default")))
        let xray = ConnectionRecord(name: "ams-1", details: .xray(XrayConnection(
            host: "203.0.113.7", uuid: "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab",
            sni: "www.transip.nl", publicKey: "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc",
            shortID: "0427f68370c8885d")))
        return (telemost, jitsi, xray)
    }

    private static func hero(state: ConnectionState, subject: ConnectionRecord, health: HealthDisplay,
                             isBest: Bool = false, throughput: ThroughputReading? = nil,
                             intensity: Double = 0) -> ConnectHero {
        ConnectHero(state: state, subject: subject, health: health,
                    exitFlag: state.isConnected ? "🇳🇱" : nil,
                    exitPlace: state.isConnected ? "Amsterdam, NL" : nil,
                    mode: .proxy, socksPort: 8808, secretsLocked: false, isPresented: true,
                    modeFallbackReason: nil, isBest: isBest,
                    throughput: throughput, waveIntensity: intensity,
                    menuItems: [], onConnect: {}, onDisconnect: {}, onChoose: {})
    }

    /// The hero on the page ground, the way the Connect tab hosts it.
    private static func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, Theme.Metrics.s4)
        }
        .background(Theme.Palette.bg)
    }

    // MARK: Rendering

    /// Renders `content` light and dark at two sizes and writes the PNGs.
    private func capture<V: View>(_ name: String, @ViewBuilder _ content: () -> V) async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene in this test host")
        }
        let view = content()
        let sizes: [(String, CGSize)] = [("native", scene.screen.bounds.size),
                                         ("375x667", CGSize(width: 375, height: 667))]
        for (sizeName, size) in sizes {
            for dark in [false, true] {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                let host = UIHostingController(rootView: view)
                window.rootViewController = host
                window.isHidden = false
                // Let onAppear, the first layout pass and the first frame land.
                try await Task.sleep(for: .milliseconds(800))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let file = Self.outputDir.appendingPathComponent(
                    "\(name)-\(sizeName)-\(dark ? "dark" : "light").png")
                try XCTUnwrap(image.pngData()).write(to: file)
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}
