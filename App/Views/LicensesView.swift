import SwiftUI

// MARK: - LicensesView
//
// Settings → About → Open-source licences. The olcrtc core comes first — its
// Apache-2.0 licence requires the licence text and its NOTICE to travel with
// the app, and its NOTICE in turn names the original upstream's WTFPL — then
// every Go module and Swift package the app links, as one generated document
// each (scripts/gen-third-party-notices.py writes App/Licenses/third-party-*).
// The texts are bundled resources, read when a row is opened.

struct LicensesView: View {

    private struct Document: Identifiable {
        /// Bundle resource name (`.txt`, or no extension for the app's LICENSE).
        let id: String
        let title: String
        let subtitle: String
    }

    private var documents: [Document] {
        [
            Document(id: "LICENSE", title: "olcOS", subtitle: "MIT"),
            Document(id: "olcrtc-NOTICE", title: L10n.licensesCoreNotice.localized(),
                     subtitle: "ghostlane-project/olcrtc"),
            Document(id: "olcrtc-LICENSE", title: L10n.licensesCoreLicense.localized(),
                     subtitle: "Apache-2.0"),
            Document(id: "olcrtc-upstream-WTFPL", title: L10n.licensesUpstream.localized(),
                     subtitle: "openlibrecommunity/olcrtc · WTFPL"),
            Document(id: "third-party-go", title: L10n.licensesGoModules.localized(),
                     subtitle: "Xray-core, Pion, Outline SDK…"),
            Document(id: "third-party-swift", title: L10n.licensesSwiftPackages.localized(),
                     subtitle: "Citadel, SwiftNIO, Swift Crypto…"),
        ]
    }

    var body: some View {
        Form {
            Section {
                ForEach(documents) { document in
                    NavigationLink {
                        LicenseTextView(title: document.title, resource: document.id)
                    } label: {
                        SignalSettingsLabel(document.title, subtitle: document.subtitle,
                                            systemImage: "doc.plaintext")
                    }
                }
            } footer: {
                Text(L10n.licensesFooter.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.licensesTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One licence document. The generated notices run to hundreds of kilobytes,
/// so the text is cut into paragraph groups and drawn lazily rather than as
/// one enormous `Text`.
struct LicenseTextView: View {
    let title: String
    let resource: String
    @State private var chunks: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Text(chunk)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.Metrics.s4)
        }
        .background(Theme.Palette.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { chunks = Self.chunks(of: Self.load(resource)) }
    }

    static func load(_ resource: String) -> String {
        let url = Bundle.main.url(forResource: resource, withExtension: "txt")
            ?? Bundle.main.url(forResource: resource, withExtension: nil)
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// Paragraphs (blank-line separated) gathered into groups of about
    /// `target` characters; joining the groups with a blank line restores
    /// the text.
    static func chunks(of text: String, target: Int = 4_000) -> [String] {
        var groups: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + paragraph.count > target {
                groups.append(current)
                current = ""
            }
            current += current.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
