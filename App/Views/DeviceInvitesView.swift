import SwiftUI

// MARK: - DeviceInvitesView
//
// Manage server → Devices. One link per device: it gives that device this
// server's connections and keeps them current — a renewed room, a new key or
// protocol reaches it without a new link (InviteSync). The device gets no SSH
// access. Revoking stops the updates; closing access for good means rotating
// the server key, which the remaining devices then receive by themselves.
//
// Where the server agent answers, each row also says whether a device that
// took the invite is connected now (or when one last was) and how much it
// moved (InviteUsage, from the agent's `GET usage`). The read never holds the
// screen up, and a failure leaves the rows as they are without it.

/// What the Manage screen needs to open Devices for one server.
struct DeviceInvitesRoute {
    let hostID: UUID
    let hosts: ServerHostStore
    let sync: InviteSync

    /// The row's subtitle on the Manage screen.
    @MainActor var subtitle: String {
        let count = hosts.hosts.first { $0.id == hostID }?.invites?.count ?? 0
        return count == 0 ? L10n.invitesRowSubtitle.localized()
                          : L10n.invitesRowCount_fmt.formatted(count)
    }
}

struct DeviceInvitesView: View {
    let hostID: UUID
    @ObservedObject var hosts: ServerHostStore
    @ObservedObject var sync: InviteSync
    /// A value input for screenshots: shown instead of the agent's answer.
    var fixedUsage: AgentUsage? = nil

    @State private var showsCreate = false
    @State private var shown: DeviceInvite?
    @State private var revoking: DeviceInvite?
    @State private var alertText: String?
    /// The agent's last answer to `GET usage`; nil before one arrives, on a
    /// server without the agent, or after a failed read.
    @State private var usage: AgentUsage?

    private var host: ServerHost? { hosts.hosts.first { $0.id == hostID } }
    private var invites: [DeviceInvite] { host?.invites ?? [] }

    var body: some View {
        Form {
            Section {
                Text(L10n.invitesExplanation.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                OlcButton(L10n.invitesCreateAction.localized(), systemImage: "person.badge.plus",
                          role: .primary, fillWidth: true) {
                    showsCreate = true
                }
            }
            .signalFormRows()

            if !invites.isEmpty {
                Section {
                    ForEach(invites) { invite in
                        Button { shown = invite } label: { inviteLabel(invite) }
                        .swipeActions(edge: .trailing) {
                            Button(L10n.invitesRevokeAction.localized(), role: .destructive) {
                                revoking = invite
                            }
                        }
                        .contextMenu {
                            Button(L10n.invitesRevokeAction.localized(), systemImage: "xmark.circle",
                                   role: .destructive) { revoking = invite }
                        }
                    }
                } header: {
                    SignalSectionHeader(L10n.invitesListHeader.localized())
                } footer: {
                    Text(L10n.invitesRevokeFooter.localized())
                }
                .signalFormRows()
            }

            if let failure = sync.failures[hostID] {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.orange)
                    OlcButton(L10n.invitesRetryAction.localized(), systemImage: "arrow.clockwise",
                              isBusy: sync.busy.contains(hostID), fillWidth: true) {
                        sync.syncSoon()
                    }
                } header: {
                    SignalSectionHeader(L10n.invitesFailureHeader.localized())
                }
                .signalFormRows()
            }
        }
        .refreshable { await loadUsage() }
        .signalFormChrome()
        .navigationTitle(L10n.invitesTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUsage() }
        .sheet(isPresented: $showsCreate) {
            CreateInviteSheet(hostID: hostID, sync: sync) { created in
                shown = created
            }
        }
        .sheet(item: $shown) { invite in
            if let host, let link = sync.link(for: invite, on: host) {
                InviteLinkSheet(name: displayName(invite), link: link)
            } else {
                InviteLinkSheet(name: displayName(invite), link: nil)
            }
        }
        .confirmationDialog(L10n.invitesRevokeTitle.localized(),
                            isPresented: Binding(get: { revoking != nil },
                                                 set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible,
                            presenting: revoking) { invite in
            Button(L10n.invitesRevokeAction.localized(), role: .destructive) {
                Task {
                    do {
                        try await sync.revoke(invite, hostID: hostID)
                    } catch {
                        alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
                    }
                }
            }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: { _ in
            Text(L10n.invitesRevokeMessage.localized())
        }
        .alert(L10n.okPrompt.localized(), isPresented: Binding(get: { alertText != nil },
                                                               set: { if !$0 { alertText = nil } })) {
            Button(L10n.ok.localized()) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
        .disabled(sync.busy.contains(hostID))
    }

    private func displayName(_ invite: DeviceInvite) -> String {
        invite.name.isEmpty ? L10n.invitesUnnamed.localized() : invite.name
    }

    @ViewBuilder
    private func inviteLabel(_ invite: DeviceInvite) -> some View {
        if let answer = fixedUsage ?? usage {
            InviteUsageLabel(title: displayName(invite), subtitle: status(invite),
                             usage: InviteUsage.summary(tag: invite.tag, in: answer))
        } else {
            SignalSettingsLabel(displayName(invite), subtitle: status(invite), systemImage: "iphone")
        }
    }

    /// Reads who used the server's invites from its agent: on appear and on a
    /// pull. Without an agent (or with Settings on SSH) there is nothing to
    /// read; any failure — an agent older than this call, no route — hides
    /// the lines rather than showing an old answer.
    @MainActor
    private func loadUsage() async {
        guard let host, let client = AgentClient.live(for: host) else { return }
        do {
            usage = try await client.usage()
        } catch is CancellationError {
            return  // the screen closed
        } catch {
            usage = nil
        }
    }

    private func status(_ invite: DeviceInvite) -> String {
        let access: String? = switch invite.agentRole {
        case "owner":  L10n.invitesAccessOwner.localized()
        case "member": L10n.invitesAccessMember.localized()
        default:       nil
        }
        let state: String
        if sync.busy.contains(hostID) {
            state = L10n.invitesStatusUploading.localized()
        } else if let published = invite.publishedAt {
            state = L10n.invitesStatusUpdated_fmt.formatted(HealthAge.phrase(Date().timeIntervalSince(published)))
        } else {
            state = L10n.invitesStatusNotUploaded.localized()
        }
        return access.map { "\($0) · \(state)" } ?? state
    }
}

// MARK: - Row with usage

/// An invite's row once the agent has answered: the name, whether a device
/// that took the invite is connected now (or when one last was), the traffic
/// those devices moved — ↓ received in the signal's cyan, ↑ sent in its
/// violet, as the hero's readout — and the invite's own state last.
private struct InviteUsageLabel: View {
    let title: String
    let subtitle: String
    let usage: InviteUsage

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
                if usage.installs > 0 { trafficLine }
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "iphone")
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
            if usage.online {
                OlcStatusDot(tone: .ok)
            } else {
                Image(systemName: usage.lastSeen == nil ? "circle.dashed" : "clock")
                    .font(Theme.Typography.label.weight(.bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(usage.statusText())
                .font(usage.online ? Theme.Typography.label : Theme.Typography.caption)
                .foregroundStyle(usage.online ? Theme.Palette.green : Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «↓ 1,2 ГБ · ↑ 85 МБ», and «· 2 устройства» when several installs took
    /// the invite (the figures are their sum).
    private var trafficLine: some View {
        let traffic: Text = piece("↓ ", Theme.Palette.signalCyan, bold: true)
            + piece(InviteUsage.bytes(usage.received), Theme.Palette.textSecondary)
            + piece(" · ", Theme.Palette.textSecondary)
            + piece("↑ ", Theme.Palette.signalViolet, bold: true)
            + piece(InviteUsage.bytes(usage.sent), Theme.Palette.textSecondary)
        let installs = usage.installs > 1 ? InviteUsage.installsText(usage.installs) : nil
        let line = installs.map { traffic + piece(" · " + $0, Theme.Palette.textSecondary) } ?? traffic
        let spoken = installs.map { usage.trafficAccessibilityText + ", " + $0 } ?? usage.trafficAccessibilityText
        return line
            .font(Theme.Typography.caption.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(spoken)
    }

    private func piece(_ text: String, _ color: Color, bold: Bool = false) -> Text {
        let segment = Text(verbatim: text).foregroundStyle(color)
        return bold ? segment.fontWeight(.bold) : segment
    }
}

// MARK: - Create

private struct CreateInviteSheet: View {
    let hostID: UUID
    @ObservedObject var sync: InviteSync
    let onCreated: (DeviceInvite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var access: InviteSync.Access = .none
    @State private var working = false
    @State private var errorText: String?

    private var canGiveAccess: Bool { sync.canGiveServerAccess(hostID: hostID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.invitesNamePlaceholder.localized(), text: $name)
                        .textInputAutocapitalization(.words)
                        .disabled(working)
                } header: {
                    SignalSectionHeader(L10n.invitesNameField.localized())
                } footer: {
                    Text(L10n.invitesCreateFooter.localized())
                }
                .signalFormRows()
                Section {
                    if canGiveAccess {
                        Picker(L10n.invitesAccessField.localized(), selection: $access) {
                            Text(L10n.invitesAccessNone.localized()).tag(InviteSync.Access.none)
                            Text(L10n.invitesAccessMember.localized()).tag(InviteSync.Access.member)
                            Text(L10n.invitesAccessOwner.localized()).tag(InviteSync.Access.owner)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .disabled(working)
                    } else {
                        Text(L10n.invitesAccessUnavailable.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    SignalSectionHeader(L10n.invitesAccessField.localized())
                } footer: {
                    Text(L10n.invitesAccessFooter.localized() + "\n" + L10n.invitesPortsNote.localized())
                }
                .signalFormRows()
                if working {
                    Section {
                        HStack(spacing: Theme.Metrics.s2) {
                            ProgressView()
                            Text(L10n.invitesStatusUploading.localized())
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .signalFormRows()
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.orange)
                    }
                    .signalFormRows()
                }
            }
            .signalFormChrome()
            .navigationTitle(L10n.invitesCreateTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: L10n.invitesCreateConfirm.localized(), disabled: working) { create() }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(working)
    }

    private func create() {
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                let invite = try await sync.create(name: name, hostID: hostID,
                                                   access: canGiveAccess ? access : .none)
                dismiss()
                onCreated(invite)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Link

struct InviteLinkSheet: View {
    let name: String
    /// nil until the list is on the server, or when the key is gone.
    let link: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    if let link {
                        Text(L10n.invitesLinkExplanation.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        QRCodeView(uri: link)
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: Theme.Metrics.s2) {
                            ShareLink(item: link, subject: Text(name)) {
                                ShareLinkLabel(title: L10n.shareAction.localized(),
                                               systemImage: "square.and.arrow.up")
                            }
                            OlcButton(L10n.invitesCopyLink.localized(), systemImage: "doc.on.doc",
                                      role: .secondary, fillWidth: true) {
                                UIPasteboard.general.string = link
                                LogStore.shared.log(.connection, "⧉ invite link copied (\(name))")
                                dismiss()
                            }
                        }
                        Text(L10n.invitesLinkSecretNote.localized())
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.invitesLinkUnavailable.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Metrics.s4)
            }
            .background(Theme.Palette.bg)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        .presentationDetents([.large])
    }
}
