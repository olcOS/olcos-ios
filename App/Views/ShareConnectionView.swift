import SwiftUI

// MARK: - Sharing
//
// Two sheets share one page:
//  • `ShareConnectionView` — one connection: explanation + the mono `olcrtc://`
//    URI + Copy / Share / QR. Used by the Connect tab.
//  • `ServerShareSheet` — the server card's "Share": device invites, or pick
//    WHICH protocol connection to share (each as its own `olcrtc://` URI / QR).
// The QR is a NavigationLink push inside the sheet's own NavigationStack.

/// One protocol connection a server card can share.
struct ServerShareOption: Identifiable, Hashable {
    let conn: ConnectionRecord
    var id: UUID { conn.id }
    /// "Yandex Telemost · VP8" — the same naming the protocol rows use.
    var title: String { ConnectionNaming.protocolLine(conn.details) }

    // `ConnectionRecord` is not Hashable (it carries the secret-bearing
    // details); identity by record id is what the navigation path needs.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ShareConnectionView: View {
    let conn: ConnectionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShareConnectionPage(conn: conn)
                .navigationTitle(L10n.shareConnectionTitle.localized())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeItem }
        }
        .presentationDetents([.medium, .large])
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(L10n.closeAction.localized())
        }
    }
}

// MARK: - Server share picker

struct ServerShareSheet: View {
    let hostLabel: String
    /// Every protocol connection this server owns, in row order.
    let options: [ServerShareOption]
    /// Device invites for this server; nil hides the section.
    var invites: DeviceInvitesRoute? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                inviteSection
                protocolSection
            }
            .signalFormChrome()
            .navigationTitle(L10n.shareServerTitle_fmt.formatted(hostLabel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// First, because it is the share that keeps working: the other device
    /// receives room and key changes without a new link.
    @ViewBuilder
    private var inviteSection: some View {
        if let invites, !options.isEmpty {
            Section {
                NavigationLink {
                    DeviceInvitesView(hostID: invites.hostID, hosts: invites.hosts, sync: invites.sync)
                } label: {
                    SignalSettingsLabel(L10n.invitesCreateAction.localized(), subtitle: invites.subtitle,
                                        systemImage: "person.2.badge.plus")
                }
            }
            .signalFormRows()
        }
    }

    private var protocolSection: some View {
        Section {
            if options.isEmpty {
                Text(L10n.shareServerNoProtocols.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(options) { option in
                NavigationLink {
                    ShareConnectionPage(conn: option.conn)
                        .navigationTitle(option.title)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    SignalSettingsLabel(option.title, systemImage: "link")
                }
            }
        } header: {
            SignalSectionHeader(L10n.shareServerProtocolsHeader.localized())
        } footer: {
            Text(L10n.shareConnectionOnlySub.localized())
        }
        .signalFormRows()
    }
}

// MARK: - Pages

/// The connection-share page: scope badge, explanation, URI, Copy / Share / QR.
struct ShareConnectionPage: View {
    let conn: ConnectionRecord
    @Environment(\.dismiss) private var dismiss

    private var uri: String { conn.details.shareURI }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                // The scope of a plain URI is the first thing on screen.
                connectionOnlyBadge

                Text(L10n.shareConnectionExplanation.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                // Answers "where do I paste this?": the URI has no consumer
                // outside olcOS, and the entry point on the other phone is
                // three taps deep.
                Text(L10n.shareRecipientHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    OlcSectionHeader(L10n.shareConnectionURIHeader.localized())
                    OlcCard {
                        Text(uri)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(spacing: Theme.Metrics.s2) {
                    OlcButton(L10n.copyURIAction.localized(), systemImage: "doc.on.doc",
                              role: .secondary, fillWidth: true) {
                        UIPasteboard.general.string = uri
                        LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                        dismiss()
                    }
                    ShareLink(item: uri, subject: Text(conn.displayName)) {
                        ShareLinkLabel(title: L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                    }
                    NavigationLink {
                        QRCodeView(uri: uri)
                            .padding(Theme.Metrics.s7)
                            .navigationTitle(ConnectionNaming.service(conn.details))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        ShareLinkLabel(title: L10n.actionQR.localized(), systemImage: "qrcode")
                    }
                }
            }
            .padding(Theme.Metrics.s4)
        }
    }

    private var connectionOnlyBadge: some View {
        OlcCard {
            HStack(spacing: Theme.Metrics.s2) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Palette.textSecondary)
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(L10n.shareConnectionOnlyBadge.localized())
                        .font(Theme.Typography.statusTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.shareConnectionOnlySub.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }
}

/// A `ShareLink` / `NavigationLink` label drawn like `OlcButton(.secondary)`.
struct ShareLinkLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Typography.button)
            .foregroundStyle(Theme.Palette.accent)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.controlHeight)
            .background(Theme.Palette.fill,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
    }
}
