import Foundation
import SwiftUI

/// Result the wizard hands back to the presenter: exactly what the old
/// `AddServerHostView` + `InstallOptionsView` pair produced, in one call.
struct AddServerFlowOutcome {
    let host: ServerHost
    let secret: SSHSecret
    /// nil when only Xray was picked.
    let primary: InstallOptions?
    let extras: [InstallOptions]
    /// Xray to install (or adopt), with the user's overrides; nil = not picked.
    let xray: XrayInstallOptions?
}

/// Telemost room creation state on the Room step.
enum AddServerTelemostState: Equatable {
    case needsSignIn
    case creating
    case created(TelemostRoom)
    case failed(message: String, needsSignIn: Bool)
}

/// SaluteJazz room creation on the Room step: one anonymous request, made as
/// soon as the step opens.
enum AddServerSaluteState: Equatable {
    case idle
    case creating
    case created
    case failed(String)
}

/// VK call / MTS Link room creation on the Room step: made by the app with the
/// user's own linked account (VKLoginView), or typed in by hand.
enum AddServerAutoRoomState: Equatable {
    /// No account linked yet — the card offers the sign-in.
    case needsSignIn
    case creating
    /// The VK call link, or the MTS Link meeting, that was made.
    case created(String)
    case failed(message: String, needsSignIn: Bool)
}

/// The Jitsi instance on the Room step: the VPS is asked which public
/// instances it can reach and that let guests in (`SSHRunner.probeJitsi`).
enum AddServerJitsiState: Equatable {
    case idle
    case checking
    /// The probe found `host` working from the server and filled it in.
    case picked(host: String)
    /// Nothing in the list answered from the server.
    case noneWorking
    case failed(String)
    /// The user chose an instance or typed an address; the probe keeps
    /// marking the menu but no longer replaces the choice.
    case custom
}

/// Where the Install step is.
enum AddServerInstallPhase: Equatable {
    case review
    case running(String)
    case success(String)
    case failure(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var isFinished: Bool {
        switch self {
        case .success, .failure: return true
        default: return false
        }
    }
}

/// All wizard state. SSH and network work runs in child tasks that the sheet
/// cancels on dismiss; the secret never leaves `access` except through
/// `makeOutcome()`.
@MainActor
final class AddServerFlowController: ObservableObject {
    @Published var step: AddServerStep = .access
    @Published var access = AddServerAccessDraft()
    @Published var showAccessErrors = false

    @Published var check: AddServerCheckState = .idle
    @Published var trust: AddServerTrustState = .firstContact

    @Published var plan: AddServerCarrierPlan = .defaultPlan

    @Published var rooms = AddServerRoomDraft()
    @Published var telemost: AddServerTelemostState = .needsSignIn
    @Published var showRoomErrors = false

    @Published var installPhase: AddServerInstallPhase = .review
    /// `serverStore.hosts` entry once the presenter saved it.
    @Published private(set) var savedHost: ServerHost?

    let otherLabels: [String]
    /// Owned here so the Room step and the controller see the same session state.
    let yandexStore = YandexSessionStore()
    /// The VK account behind the auto-created rooms, same reason.
    let vkStore = VKSessionStore()
    let mtsStore = MTSLinkSessionStore()
    /// The one path of every MTS Link Make a room (replay, then the sheet).
    let mtsMaker = MTSLinkRoomMaker()

    @Published var jitsi: AddServerJitsiState = .idle
    @Published var salute: AddServerSaluteState = .idle
    @Published var vk: AddServerAutoRoomState = .needsSignIn
    @Published var mts: AddServerAutoRoomState = .needsSignIn
    /// The MTS Link meeting is being checked before the wizard moves on, and
    /// why the last check refused it.
    @Published private(set) var checkingMTS = false
    @Published var mtsRefusal: String?
    /// Instances the last probe found working, marked in the instance menu.
    @Published private(set) var workingJitsiHosts: Set<String> = []

    private var checkTask: Task<Void, Never>?
    private var telemostTask: Task<Void, Never>?
    private var jitsiTask: Task<Void, Never>?
    private var saluteTask: Task<Void, Never>?
    private var vkTask: Task<Void, Never>?
    private var mtsTask: Task<Void, Never>?
    private var mtsCheckTask: Task<Void, Never>?

    init(otherLabels: [String]) {
        self.otherLabels = otherLabels
    }

    // MARK: Navigation

    var accessErrors: [AddServerAccessDraft.FieldError] { access.validate(otherLabels: otherLabels) }
    var roomErrors: [AddServerRoomDraft.RoomError] { rooms.validate(plan: plan) }

    func canAdvance(from step: AddServerStep) -> Bool {
        switch step {
        case .access:    return accessErrors.isEmpty
        case .check:     return check.isDone && trust != .mismatch
        case .protocols: return plan.hasAnything && plan.xrayOptionsValid
        case .room:      return roomErrors.isEmpty
        case .install:   return false
        }
    }

    var canGoBack: Bool {
        step != .access && !installPhase.isRunning && !installPhase.isFinished
    }

    func advance() {
        switch step {
        case .access:
            showAccessErrors = true
            guard canAdvance(from: .access) else { return }
        case .room:
            showRoomErrors = true
            guard canAdvance(from: .room) else { return }
            // The MTS Link meeting is checked before the wizard moves on.
            if needsMTS {
                checkMTSMeeting()
                return
            }
        default:
            guard canAdvance(from: step) else { return }
        }
        moveOn()
    }

    private func moveOn() {
        guard var next = step.next else { return }
        // Only call carriers have rooms; an Xray-only plan has nothing to ask.
        if next == .room, plan.isEmpty, let after = next.next { next = after }
        Haptics.tap()
        withAnimation(.snappy) { step = next }
        if next == .check, check == .idle { startCheck() }
        if next == .room {
            startTelemostIfNeeded()
            startJitsiIfNeeded()
            startSaluteIfNeeded()
            startVKIfNeeded()
        }
    }

    func goBack() {
        guard canGoBack, var prev = step.previous else { return }
        if prev == .room, plan.isEmpty, let before = prev.previous { prev = before }
        withAnimation(.snappy) { step = prev }
    }

    func cancelWork() {
        checkTask?.cancel()
        telemostTask?.cancel()
        jitsiTask?.cancel()
        saluteTask?.cancel()
        vkTask?.cancel()
        mtsTask?.cancel()
        mtsCheckTask?.cancel()
    }

    // MARK: Step 2 — SSH check

    func startCheck() {
        guard let host = access.makeHost(), let secret = access.makeSecret() else { return }
        checkTask?.cancel()
        check = .running
        trust = AddServerTrustState.current(host: host.host, port: host.port)
        checkTask = Task { [weak self] in
            let result = await AddServerProbe.run(host: host, secret: secret)
            guard let self, !Task.isCancelled else { return }
            self.trust = AddServerTrustState.current(host: host.host, port: host.port)
            switch result {
            case .success(let facts):
                self.check = .done(facts)
            case .failure(let error):
                // A refused login gets the plain sentence; the raw Citadel
                // text stays in the log.
                let raw = error.localizedDescription
                let reason = HealthFailureMapper.reason(forSSH: raw)
                LogStore.shared.log(.provisioning, "✗ add server: SSH check failed — \(raw)")
                self.check = .failed(reason == .sshAuth ? reason.message : raw)
            }
        }
    }

    /// The Access step changed → the previous check no longer applies, and
    /// neither does what another server could reach.
    func invalidateCheck() {
        checkTask?.cancel()
        check = .idle
        jitsiTask?.cancel()
        workingJitsiHosts = []
        if jitsi != .custom { jitsi = .idle }
    }

    // MARK: Step 4 — Jitsi instance

    var needsJitsi: Bool { plan.selected.contains("jitsi") }

    func startJitsiIfNeeded() {
        guard needsJitsi, jitsi == .idle else { return }
        probeJitsi()
    }

    /// Asks the VPS which instances work and fills in the first one in
    /// `CarrierEndpoints.jitsiInstances` order, unless the user has chosen.
    func probeJitsi() {
        guard let host = access.makeHost(), let secret = access.makeSecret() else { return }
        jitsiTask?.cancel()
        if jitsi != .custom { jitsi = .checking }
        let candidates = CarrierEndpoints.jitsiInstances
        jitsiTask = Task { [weak self] in
            do {
                let probes = try await SSHRunner.probeJitsi(host: host, secret: secret, candidates: candidates)
                guard let self, !Task.isCancelled else { return }
                self.workingJitsiHosts = Set(probes.filter(\.isUsable).map(\.host))
                guard self.jitsi == .checking else { return }
                if let best = SSHRunner.bestJitsiHost(probes, order: candidates) {
                    self.rooms.jitsiBaseURL = CarrierEndpoints.jitsiBaseURL(forInstance: best)
                    self.jitsi = .picked(host: best)
                } else {
                    self.jitsi = .noneWorking
                }
            } catch {
                guard let self, !Task.isCancelled, self.jitsi == .checking else { return }
                self.jitsi = .failed(error.localizedDescription)
            }
        }
    }

    /// The user picked an instance or typed an address: it stays.
    func chooseJitsi(_ baseURL: String) {
        rooms.jitsiBaseURL = baseURL
        jitsi = .custom
    }

    // MARK: Step 4 — SaluteJazz room

    var needsSalute: Bool { plan.selected.contains("salutejazz") }

    func startSaluteIfNeeded() {
        guard needsSalute, rooms.saluteRoom.isEmpty, salute != .creating else { return }
        createSaluteRoom()
    }

    func createSaluteRoom() {
        saluteTask?.cancel()
        salute = .creating
        saluteTask = Task { [weak self] in
            do {
                let room = try await SaluteJazzRoomService.createRoom()
                guard let self, !Task.isCancelled else { return }
                self.rooms.saluteRoom = room
                self.salute = .created
                Haptics.success()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.salute = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Step 4 — Telemost room

    var needsTelemost: Bool { plan.selected.contains("telemost") }

    func startTelemostIfNeeded() {
        guard needsTelemost, rooms.telemostRoomID.isEmpty else { return }
        if yandexStore.hasSession { createTelemostRoom() } else { telemost = .needsSignIn }
    }

    /// Called by the Yandex login sheet with the raw session value; stored in
    /// Keychain by the store, never kept here.
    func yandexSignedIn(_ session: String) {
        guard yandexStore.save(session) else {
            telemost = .failed(message: L10n.telemostErrSessionRejected.localized(), needsSignIn: true)
            return
        }
        createTelemostRoom()
    }

    func createTelemostRoom() {
        telemostTask?.cancel()
        telemost = .creating
        telemostTask = Task { [weak self] in
            do {
                let room = try await TelemostRoomService.createRoom()
                guard let self, !Task.isCancelled else { return }
                self.rooms.telemostRoomID = room.id
                self.rooms.telemostRoomURI = room.uri
                self.rooms.telemostRoomCreatedAt = Date()
                self.telemost = .created(room)
                Haptics.success()
            } catch {
                guard let self, !Task.isCancelled else { return }
                let needsSignIn = (error as? TelemostRoomError)?.needsSignIn ?? false
                self.telemost = .failed(message: error.localizedDescription, needsSignIn: needsSignIn)
            }
        }
    }

    func switchYandexAccount() {
        telemostTask?.cancel()
        yandexStore.clear()
        rooms.telemostRoomID = ""
        rooms.telemostRoomURI = ""
        rooms.telemostRoomCreatedAt = nil
        telemost = .needsSignIn
    }

    // MARK: Step 4 — VK call

    var needsVK: Bool { plan.selected.contains("vkcalls") }

    func startVKIfNeeded() {
        guard needsVK, rooms.vkLink.isEmpty else { return }
        if vkStore.hasSession { createVKCall() } else { vk = .needsSignIn }
    }

    /// Called by the VK login sheet with the raw session value; stored in
    /// Keychain by the store, never kept here.
    func vkSignedIn(_ session: String) {
        guard vkStore.save(session) else {
            vk = .failed(message: L10n.vkErrSessionRejected.localized(), needsSignIn: true)
            return
        }
        createVKCall()
    }

    func createVKCall() {
        vkTask?.cancel()
        vk = .creating
        vkTask = Task { [weak self] in
            do {
                let room = try await VKCallRoomService.createRoom()
                guard let self, !Task.isCancelled else { return }
                self.rooms.vkLink = room.link
                self.rooms.vkRoomCreatedAt = Date()   // rotation's clock starts at creation
                self.vk = .created(room.link)
                Haptics.success()
            } catch {
                guard let self, !Task.isCancelled else { return }
                let needsSignIn = (error as? VKCallRoomError)?.needsSignIn ?? false
                self.vk = .failed(message: error.localizedDescription, needsSignIn: needsSignIn)
            }
        }
    }

    func switchVKAccount() {
        vkTask?.cancel()
        vkStore.clear()
        rooms.vkLink = ""
        rooms.vkRoomCreatedAt = nil
        vk = .needsSignIn
    }

    // MARK: Step 4 — MTS Link meeting

    var needsMTS: Bool { plan.selected.contains("mtslink") }

    /// The state the card starts in: nothing made yet (`.needsSignIn` stands
    /// for "no room made so far" here — a permanent meeting counts against the
    /// plan's cap, so none is made until the owner presses the button).
    ///
    /// "Make a room": the silent replay first; the sign-in sheet in create
    /// mode (MTSLinkRoomMaker) when there is nothing to replay or it failed.
    func createMTSRoom() {
        mtsTask?.cancel()
        mts = .creating
        mtsTask = Task { [weak self] in
            guard let self else { return }
            let link = await self.mtsMaker.makeRoom(current: self.rooms.mtsLink)
            guard !Task.isCancelled else { return }
            if let link {
                self.rooms.mtsLink = link
                self.rooms.mtsRoomCreatedAt = Date()   // rotation's clock starts at creation
                self.mts = .created(link)
                Haptics.success()
            } else {
                self.mts = .needsSignIn
            }
        }
    }

    func switchMTSAccount() {
        mtsTask?.cancel()
        mtsStore.clear()
        rooms.mtsLink = ""
        rooms.mtsRoomCreatedAt = nil
        mts = .needsSignIn
        mtsRefusal = nil
    }

    /// Next on the room step: only a meeting the server can enter moves the
    /// wizard on; anything else stays here with its one line.
    func checkMTSMeeting() {
        guard !checkingMTS else { return }
        let link = rooms.mtsLink
        checkingMTS = true
        mtsRefusal = nil
        mtsCheckTask = Task { [weak self] in
            let verdict = await MTSLinkMeetingCheck.check(link: link)
            guard let self, !Task.isCancelled else { return }
            self.checkingMTS = false
            guard self.step == .room, self.rooms.mtsLink == link else { return }
            if let refusal = verdict.refusal {
                self.mtsRefusal = refusal
                Haptics.error()
                return
            }
            self.moveOn()
        }
    }

    // MARK: Step 5 — outcome

    func makeOutcome() -> AddServerFlowOutcome? {
        guard let host = access.makeHost(), let secret = access.makeSecret(),
              plan.hasAnything, plan.xrayOptionsValid else { return nil }
        let options = plan.installOptions(rooms: rooms)
        return AddServerFlowOutcome(host: host, secret: secret,
                                    primary: options?.primary, extras: options?.extras ?? [],
                                    xray: plan.xray ? plan.xrayOptions : nil)
    }

    func markInstallStarted(host: ServerHost) {
        savedHost = host
        installPhase = .running(L10n.addFlowInstallRunning.localized())
    }

    /// Mirrors `Provisioner.status` into the wizard once the install started.
    func observe(_ status: ProvisionStatus) {
        guard savedHost != nil, !installPhase.isFinished else { return }
        switch status {
        case .idle: break
        case .running(let text): installPhase = .running(text)
        case .success(let text): installPhase = .success(text); Haptics.success()
        case .failure(let text): installPhase = .failure(text); Haptics.error()
        }
    }
}

// MARK: - SSH probe (step 2)

/// One SSH session: learn (or verify) the host key through the normal
/// `SSHRunner` path, then collect facts. Runs off the main actor.
enum AddServerProbe {
    static func run(host: ServerHost, secret: SSHSecret) async -> Result<AddServerHostFacts, Error> {
        do {
            let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
                try await SSHRunner._execute(client: client, label: "probe",
                                             command: AddServerHostFacts.script)
            }
            return .success(AddServerHostFacts.parse(output))
        } catch {
            return .failure(error)
        }
    }
}
