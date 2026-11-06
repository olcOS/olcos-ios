import SwiftUI
import UniformTypeIdentifiers

// MARK: - WelcomeView
//
// What the Connect tab shows while there is nothing to connect to. Two ways in,
// side by side, because they are different people:
//   • someone who was SENT something — a connection link, a subscription, a
//     device invite, a QR code, a file — and has no server of their own;
//   • someone with a VPS (an address and a root password), for whom olcOS
//     installs everything.
// A third, quieter card answers "neither": the ready-made lists of free
// servers, or how to get an invite or a VPS.
// Everything imported here goes through MainTabView's one confirm-then-import
// flow, the same one a deep link takes.

struct WelcomeView: View {
    /// Text pasted, scanned or read from a file.
    let onImportText: (String) -> Void
    /// Open the add-server wizard.
    let onAddServer: () -> Void
    /// Type a connection in by hand.
    let onManual: () -> Void
    /// Open the ready-made lists of free servers.
    var onCurated: () -> Void = {}

    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showHelp = false
    @State private var fileError: String?
    /// Text the scanner brought in, imported once its sheet has gone: the
    /// confirm alert the import raises is lost under a sheet still closing.
    @State private var pendingImport: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                    Text(L10n.welcomeTitle.localized())
                        .font(Theme.Typography.answer)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.welcomeLead.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Theme.Metrics.s4)
                importCard
                serverCard
                neitherCard
                Button(L10n.welcomeManualAction.localized(), action: onManual)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.controlHeight)
            }
            .padding(.horizontal, Theme.Metrics.s4)
            .padding(.bottom, Theme.Metrics.s6)
        }
        .background(Theme.Palette.bg)
        .sheet(isPresented: $showScanner, onDismiss: importPending) {
            QRScannerSheet { scanned in
                pendingImport = scanned
                showScanner = false
            }
        }
        .photoQRImport(isPresented: $showPhotoPicker,
                       onResult: { onImportText($0) },
                       onFailure: { fileError = $0 })
        .sheet(isPresented: $showHelp) { NoServerHelpView(onAddServer: onAddServer) }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: ImportFile.contentTypes) { result in
            readFile(result)
        }
        .alert(L10n.okPrompt.localized(), isPresented: Binding(get: { fileError != nil },
                                                               set: { if !$0 { fileError = nil } })) {
            Button(L10n.ok.localized()) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    // MARK: Cards

    private var importCard: some View {
        WelcomeCard(systemImage: "link",
                    title: L10n.welcomeImportTitle.localized(),
                    detail: L10n.welcomeImportBody.localized()) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Metrics.s2) { importButtons }
                VStack(spacing: Theme.Metrics.s2) { importButtons }
            }
        }
    }

    @ViewBuilder
    private var importButtons: some View {
        OlcButton(L10n.pasteAction.localized(), systemImage: "doc.on.clipboard",
                  role: .primary, fillWidth: true) {
            onImportText(UIPasteboard.general.string ?? "")
        }
        OlcButton(L10n.welcomeScanAction.localized(), systemImage: "qrcode.viewfinder",
                  role: .secondary, fillWidth: true) { showScanner = true }
        OlcButton(L10n.addMenuPhoto.localized(), systemImage: "photo.on.rectangle",
                  role: .secondary, fillWidth: true) { showPhotoPicker = true }
        OlcButton(L10n.welcomeFileAction.localized(), systemImage: "doc",
                  role: .secondary, fillWidth: true) { showFilePicker = true }
    }

    private var serverCard: some View {
        WelcomeCard(systemImage: "server.rack",
                    title: L10n.welcomeServerTitle.localized(),
                    detail: L10n.welcomeServerBody.localized()) {
            VStack(spacing: Theme.Metrics.s2) {
                OlcButton(L10n.welcomeServerAction.localized(), systemImage: "plus.circle",
                          role: .primary, fillWidth: true, action: onAddServer)
                // A server another phone already runs: an invite with
                // management access brings the server and its connections in,
                // nothing installed.
                OlcButton(L10n.welcomePasteAccessAction.localized(), systemImage: "key.horizontal",
                          role: .secondary, fillWidth: true) {
                    onImportText(UIPasteboard.general.string ?? "")
                }
            }
        }
    }

    private var neitherCard: some View {
        WelcomeCard(systemImage: "questionmark.circle",
                    title: L10n.welcomeNeitherTitle.localized(),
                    detail: L10n.welcomeNeitherBody.localized()) {
            VStack(spacing: Theme.Metrics.s2) {
                OlcButton(L10n.welcomeFreeServersAction.localized(), systemImage: "list.bullet.rectangle",
                          role: .secondary, fillWidth: true, action: onCurated)
                OlcButton(L10n.welcomeNeitherAction.localized(), systemImage: "book",
                          role: .ghost, fillWidth: true) { showHelp = true }
            }
        }
    }

    private func importPending() {
        guard let text = pendingImport else { return }
        pendingImport = nil
        onImportText(text)
    }

    // MARK: File

    private func readFile(_ result: Result<URL, Error>) {
        switch ImportFile.read(result) {
        case .text(let text):       onImportText(text)
        case .failure(let message): fileError = message
        }
    }

    /// UTF-8 text, a UTF-8 BOM dropped; nil for anything binary.
    nonisolated static func text(from data: Data) -> String? { ImportFile.text(from: data) }
}

/// One way in: a glyph, what it is, who it is for, and its actions.
private struct WelcomeCard<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                    Image(systemName: systemImage)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: Theme.Metrics.s7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                        Text(title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                actions()
            }
        }
    }
}

// MARK: - NoServerHelpView

/// "I have neither": the two honest ways to get somewhere to connect to.
struct NoServerHelpView: View {
    let onAddServer: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    step(number: 1, title: L10n.noServerInviteTitle.localized(),
                         text: L10n.noServerInviteBody.localized())
                    step(number: 2, title: L10n.noServerRentTitle.localized(),
                         text: L10n.noServerRentBody.localized())
                    OlcButton(L10n.welcomeServerAction.localized(), systemImage: "plus.circle",
                              role: .primary, fillWidth: true) {
                        dismiss()
                        onAddServer()
                    }
                }
                .padding(Theme.Metrics.s4)
            }
            .background(Theme.Palette.bg)
            .navigationTitle(L10n.welcomeNeitherTitle.localized())
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

    private func step(number: Int, title: String, text: String) -> some View {
        OlcCard {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                Text("\(number)")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: Theme.Metrics.s6)
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(title)
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(text)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
