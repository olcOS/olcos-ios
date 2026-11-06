import SwiftUI

// MARK: - ProtocolPageView
//
// One protocol on one server, pushed from its row on the server card. It
// answers three questions in order: does it work (the measured verdict, with
// Connect and Check), which rooms is it in (the main one and the extra rooms a
// whole-server connection joins at once; each room can get a new room the app
// makes itself where the service allows it — and where it cannot the reason is
// said plainly — or one typed in; an extra room can be removed right here), and
// how is it set up (transport and service settings, start and stop, remove).
//
// Every action shows its progress on the control that started it and its
// result in one line under the verdict (`ProtocolOpStatus`): nobody has to go
// back to the server card to learn whether it worked.
//
// Plain values and closures only: ServersView resolves them on every render —
// it owns the stores, the SSH lane and every dialog — and this file draws.
// That file has blown the type-checker's budget three times; new UI lives here.

/// One room of a protocol: the main one (number 1) or an extra one.
struct ProtocolRoom: Identifiable, Equatable {
    /// The container that sits in this room.
    let id: String
    let number: Int
    let room: String
    let isRunning: Bool
    var isMain: Bool { number == 1 }
}

/// The one operation a protocol page started, and how it is going. The page
/// shows its progress on the control that started it and its result in a line
/// of its own, so nobody has to leave the page to learn whether it worked.
struct ProtocolOpStatus: Equatable {
    enum Kind: Equatable {
        case verify
        case startStop
        /// A new room made for this room (the room's container).
        case newRoom(String)
        /// Settings or a typed room, for this container.
        case reconfigure(String)
        case addRoom
        case removeRoom(String)
        case recover
        case removeProtocol
    }

    enum Phase: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    /// The main container of the page this belongs to.
    let container: String
    let kind: Kind
    let phase: Phase

    var isRunning: Bool { phase == .running }

    /// How an action ended, read from what it left behind: a failure it raised
    /// (the alert the actions use, or the host card's failed state), or its
    /// success sentence. nil when there is nothing to report — it did nothing
    /// (a sheet closed without a choice), or a question is waiting.
    static func outcome(alert: String?, ran: Bool, hostFailure: String?,
                        questionPending: Bool, note: String?, success: String) -> Phase? {
        if let alert { return .failed(alert) }
        if !ran { return nil }
        if let hostFailure { return .failed(hostFailure) }
        if questionPending { return nil }
        return .done(note ?? success)
    }
}

struct ProtocolPageView: View {
    /// Service name ("Jitsi").
    let title: String
    /// Transport label ("DataChannel").
    let transport: String
    let health: HealthDisplay
    /// The live session runs through this protocol.
    let isLive: Bool
    /// Its server-side process is up.
    let isRunning: Bool
    /// Its container is gone (its settings file is still there): Start re-creates it.
    var isMissing = false
    /// A new check of this protocol is under way; `health` is still the last one.
    var isChecking = false
    /// What the last action taken on this page is doing or did.
    var operation: ProtocolOpStatus? = nil
    /// The main room first, then the extra ones.
    let rooms: [ProtocolRoom]
    /// The app makes a new room by itself (Jitsi, SaluteJazz, Telemost signed in).
    let makesRooms: Bool
    /// Telemost with no Yandex sign-in stored yet.
    let needsYandexSignIn: Bool
    let canAddRoom: Bool
    /// Why the app cannot make a room for this protocol right now, in words;
    /// nil when it can. Said under the disabled "New room, made automatically"
    /// instead of a button that would fail quietly (MTS Link until the app has
    /// seen the service make a meeting).
    let createUnavailableReason: String?
    /// Another operation holds the server: every action waits.
    let busy: Bool
    /// What the service and the transport are, one line each.
    let detailLines: [String]
    let onConnect: () -> Void
    let onVerify: () -> Void
    let onStartStop: () -> Void
    let onNewRoom: (ProtocolRoom) -> Void
    let onTypeRoom: (ProtocolRoom) -> Void
    let onAddRoom: () -> Void
    let onRemoveRoom: (ProtocolRoom) -> Void
    let onSettings: () -> Void
    /// The raw Yandex `Session_id` from the sign-in web view; the caller stores it.
    let onSignedIn: (String) -> Void
    /// Why the last check failed, in words; nil when it did not.
    var onShowReason: (() -> Void)? = nil
    /// Re-read this protocol's connection from the server; nil when it matches.
    var onRecover: (() -> Void)? = nil
    /// Remove the protocol from the server; nil for the server's first one.
    var onRemove: (() -> Void)? = nil

    @State private var showLogin = false

    var body: some View {
        Form {
            statusSection
            operationSection
            roomsSection
            setupSection
            removeSection
        }
        .signalFormChrome()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy || (operation?.isRunning ?? false))
        .sheet(isPresented: $showLogin) {
            YandexLoginView { session in
                showLogin = false
                onSignedIn(session)
            }
        }
    }

    // MARK: Does it work

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                ServerSignalStatus(tone: health.tone,
                                   title: health.standing == .working ? ProtocolStanding.working.title : health.title,
                                   subtitle: health.subtitle, isBusy: health.isChecking || isChecking)
                if let state = stateLine {
                    Text(state)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
            if !isLive {
                actionRow(L10n.actionConnect.localized(), systemImage: "personalhotspot", action: onConnect)
            }
            actionRow(L10n.healthActionVerify.localized(), systemImage: "checkmark.shield",
                      isBusy: isOperationRunning(.verify), action: onVerify)
            if let onShowReason {
                actionRow(L10n.healthShowReasonAction.localized(), systemImage: "questionmark.circle",
                          action: onShowReason)
            }
        } header: {
            SignalSectionHeader(transport.isEmpty ? title : "\(title) · \(transport)")
        }
        .signalFormRows()
    }

    private var stateLine: String? {
        if isLive { return L10n.protocolLiveBadge.localized() }
        if !isRunning { return L10n.protocolStoppedNote.localized() }
        return nil
    }

    // MARK: What the last action did

    /// One line, there while an action runs and after it: a spinner, a check
    /// or a warning, and the sentence. It sits where the eye already is (under
    /// the verdict), so a result never needs a trip back to the server card.
    @ViewBuilder
    private var operationSection: some View {
        if let operation {
            Section {
                HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                    operationGlyph(operation.phase)
                    Text(operationText(operation))
                        .font(Theme.Typography.body)
                        .foregroundStyle(operationColor(operation.phase))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Metrics.s1)
                .accessibilityElement(children: .combine)
            }
            .signalFormRows()
        }
    }

    @ViewBuilder
    private func operationGlyph(_ phase: ProtocolOpStatus.Phase) -> some View {
        switch phase {
        case .running:
            ProgressView().controlSize(.small)
                .accessibilityHidden(true)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.orange)
                .accessibilityHidden(true)
        }
    }

    private func operationText(_ operation: ProtocolOpStatus) -> String {
        switch operation.phase {
        case .running:
            return operation.kind == .verify ? L10n.healthChecking.localized()
                                             : L10n.protocolOpWorking.localized()
        case .done(let text), .failed(let text):
            return text
        }
    }

    private func operationColor(_ phase: ProtocolOpStatus.Phase) -> Color {
        switch phase {
        case .running, .failed: return Theme.Palette.textSecondary
        case .done:             return Theme.Palette.textPrimary
        }
    }

    /// Whether this exact action is the one running: its control shows the spinner.
    private func isOperationRunning(_ kind: ProtocolOpStatus.Kind) -> Bool {
        guard let operation, operation.isRunning else { return false }
        return operation.kind == kind
    }

    // MARK: Rooms

    private var roomsSection: some View {
        Section {
            ForEach(rooms) { room in
                roomRow(room)
            }
            if needsYandexSignIn {
                actionRow(L10n.telemostRoomSignInAction.localized(), systemImage: "person.badge.key") {
                    showLogin = true
                }
            } else if canAddRoom {
                actionRow(L10n.protocolAddRoom.localized(), systemImage: "plus.circle",
                          isBusy: isOperationRunning(.addRoom), action: onAddRoom)
            }
        } header: {
            SignalSectionHeader(L10n.protocolRoomsHeader.localized())
        } footer: {
            Text(roomsFooter)
        }
        .signalFormRows()
    }

    /// What a new room takes for this protocol: the app makes them itself, the
    /// reason it cannot yet (the plain sentence under the disabled action), or
    /// the fact that the rooms come from the user.
    private var roomsFooter: String {
        if let createUnavailableReason { return createUnavailableReason }
        return (makesRooms ? L10n.protocolRoomsFooterAuto : L10n.protocolRoomsFooterManual).localized()
    }

    /// One room: what it is, and its three managements — a new room made
    /// automatically (disabled, with the reason in the section footer, where
    /// the app cannot make one), a room entered by hand, and — for an extra
    /// room — removing exactly that room. The two actions keep their size: the
    /// room's name and id take the rest of the width, and wrap.
    private func roomRow(_ room: ProtocolRoom) -> some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(room.isMain ? L10n.protocolMainRoom.localized()
                                 : L10n.protocolExtraRoom_fmt.formatted(room.number))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(room.room.isEmpty ? "—" : room.room)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !room.isRunning {
                    Text(L10n.protocolStoppedNote.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button { onNewRoom(room) } label: {
                    Label(L10n.protocolNewRoomAuto.localized(), systemImage: "sparkles")
                }
                .disabled(!makesRooms)
                Button { onTypeRoom(room) } label: {
                    Label(L10n.protocolTypeRoom.localized(), systemImage: "keyboard")
                }
            } label: {
                HStack(spacing: Theme.Metrics.s1) {
                    if isChangingRoom(room) { ProgressView().controlSize(.small) }
                    Text(L10n.protocolChangeRoom.localized())
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(Theme.Signal.stroke)
                }
                .fixedSize()
                .frame(minHeight: Theme.Metrics.controlHeight)
            }
            // The main room goes only with the protocol itself (Remove
            // protocol below); every extra room is removable here.
            if !room.isMain {
                OlcTapButton(role: .destructive, action: { onRemoveRoom(room) }) {
                    HStack(spacing: Theme.Metrics.s1) {
                        if isOperationRunning(.removeRoom(room.id)) { ProgressView().controlSize(.small) }
                        Text(L10n.laneRemoveAction.localized())
                            .font(Theme.Typography.captionStrong)
                            .foregroundStyle(Theme.Palette.red)
                    }
                    .fixedSize()
                    .frame(minHeight: Theme.Metrics.controlHeight)
                }
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
    }

    /// A new room is being made for this room, or its settings are being saved.
    private func isChangingRoom(_ room: ProtocolRoom) -> Bool {
        isOperationRunning(.newRoom(room.id)) || isOperationRunning(.reconfigure(room.id))
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            actionRow(L10n.protocolSettingsAction.localized(), systemImage: "slider.horizontal.3",
                      isBusy: isOperationRunning(.reconfigure(rooms.first?.id ?? "")),
                      action: onSettings)
            actionRow(startStopTitle, systemImage: isRunning ? "stop.fill" : "play.fill",
                      isBusy: isOperationRunning(.startStop), action: onStartStop)
            if let onRecover {
                actionRow(L10n.actionRecoverConnection.localized(), systemImage: "arrow.counterclockwise.circle",
                          isBusy: isOperationRunning(.recover), action: onRecover)
            }
        } header: {
            SignalSectionHeader(L10n.protocolSetupHeader.localized())
        } footer: {
            if !detailLines.isEmpty {
                Text(detailLines.joined(separator: "\n"))
            }
        }
        .signalFormRows()
    }

    private var startStopTitle: String {
        if isRunning { return L10n.protocolStopAction.localized() }
        if isMissing { return L10n.protocolRecreateAction.localized() }
        return L10n.protocolStartAction.localized()
    }

    @ViewBuilder
    private var removeSection: some View {
        if let onRemove {
            Section {
                OlcTapButton(role: .destructive, action: onRemove) {
                    Label {
                        Text(L10n.removeProtocolAction.localized())
                    } icon: {
                        if isOperationRunning(.removeProtocol) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "trash")
                        }
                    }
                    .font(Theme.Typography.body)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
            }
            .signalFormRows()
        }
    }

    // MARK: Row

    /// One action: its icon, or a spinner in the icon's place while this very
    /// action runs (the row keeps its size, and the title stays).
    private func actionRow(_ title: String, systemImage: String, isBusy: Bool = false,
                           action: @escaping () -> Void) -> some View {
        OlcTapButton(action: action) {
            Label {
                Text(title)
            } icon: {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(minHeight: Theme.Metrics.controlHeight)
    }
}
