import SwiftUI
import UniformTypeIdentifiers

// MARK: - AddSourcesMenu
//
// The «+» in the top right corner of the Home and Servers tabs: every way a
// connection gets into the app, in the order people use them. Everything it
// brings in goes through MainTabView's one confirm-then-import flow, the same
// one a deep link takes. The user's own server comes last: it is the extra
// path, for someone with a VPS.

struct AddSourcesMenu: View {
    let onPaste: () -> Void
    let onScan: () -> Void
    let onPhoto: () -> Void
    let onFile: () -> Void
    let onLink: () -> Void
    let onCurated: () -> Void
    let onManual: () -> Void
    let onOwnServer: () -> Void

    var body: some View {
        Menu {
            Button(action: onPaste) {
                Label(L10n.addMenuPaste.localized(), systemImage: "doc.on.clipboard")
            }
            Button(action: onScan) {
                Label(L10n.addMenuScan.localized(), systemImage: "qrcode.viewfinder")
            }
            Button(action: onPhoto) {
                Label(L10n.addMenuPhoto.localized(), systemImage: "photo.on.rectangle")
            }
            Button(action: onFile) {
                Label(L10n.addMenuFile.localized(), systemImage: "doc")
            }
            Button(action: onLink) {
                Label(L10n.addMenuLink.localized(), systemImage: "link")
            }
            Button(action: onCurated) {
                Label(L10n.addMenuCurated.localized(), systemImage: "list.bullet.rectangle")
            }
            Button(action: onManual) {
                Label(L10n.addMenuManual.localized(), systemImage: "square.and.pencil")
            }
            Divider()
            Button(action: onOwnServer) {
                Label(L10n.addMenuOwnServer.localized(), systemImage: "server.rack")
            }
        } label: {
            Image(systemName: "plus")
                .font(Theme.Typography.title)
        }
        .accessibilityLabel(L10n.addMenuTitle.localized())
    }
}

// MARK: - LinkEntrySheet

/// A subscription address or a connection link, typed or pasted.
struct LinkEntrySheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormField(label: L10n.addLinkField.localized(),
                              placeholder: L10n.addLinkPlaceholder.localized(),
                              text: $text, keyboard: .URL, mono: true,
                              helper: L10n.addLinkHelper.localized())
                }
                .signalFormRows()
            }
            .signalFormChrome()
            .navigationTitle(L10n.addMenuLink.localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: L10n.addLinkAction.localized(), icon: "plus.circle",
                      disabled: trimmed.isEmpty) {
                let value = trimmed
                dismiss()
                onSubmit(value)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Reading an imported file

enum ImportFile {
    /// The types the file picker offers: a list is plain text, often saved
    /// with an unusual extension.
    static let contentTypes: [UTType] = [.plainText, .text, .json, .data]

    /// A list is a few kilobytes; a bigger file is not one.
    static let maxBytes = 1 << 20

    /// UTF-8 text, a UTF-8 BOM dropped; nil for anything binary.
    static func text(from data: Data) -> String? {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: Data(body), encoding: .utf8), !text.contains("\u{0}") else { return nil }
        return text
    }

    enum Outcome {
        case text(String)
        case failure(String)
    }

    /// The text of a picked file, or the reason it cannot be one.
    static func read(_ result: Result<URL, Error>) -> Outcome {
        switch result {
        case .failure(let error):
            return .failure(error.localizedDescription)
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= maxBytes,
                  let content = ImportFile.text(from: data) else {
                return .failure(L10n.welcomeFileUnreadable.localized())
            }
            return .text(content)
        }
    }
}
