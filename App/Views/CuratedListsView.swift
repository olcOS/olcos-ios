import SwiftUI

// MARK: - CuratedListsView
//
// Ready-made lists of free servers that other people keep up to date, added
// like any subscription: the app re-reads a list as often as its header asks
// (hourly for these) and checks the servers in it. The lists are igareck's
// (github.com/igareck/vpn-configs-for-russia). The white lists are fetched
// through Yandex Translate's page proxy, the way their author recommends: on a
// mobile network that lets only allowed sites through, that proxy still
// answers when the list's own host does not.

enum CuratedLists {
    struct Entry: Identifiable, Equatable {
        let id: String
        let title: L10n
        let detail: L10n
        let url: String
    }

    static let source = "github.com/igareck/vpn-configs-for-russia"

    private static let viaTranslate =
        "https://translate.yandex.ru/translate?url=https://bitbucket.org/igareck/vpn-configs-for-russia/raw/main/"

    static let all: [Entry] = [
        Entry(id: "white-mobile", title: .curatedWhiteMobileTitle, detail: .curatedWhiteMobileDetail,
              url: viaTranslate + "Vless-Reality-White-Lists-Rus-Mobile.txt&lang=de-de"),
        Entry(id: "white-checked", title: .curatedWhiteCheckedTitle, detail: .curatedWhiteCheckedDetail,
              url: viaTranslate + "WHITE-CIDR-RU-checked.txt&lang=de-de"),
        Entry(id: "black", title: .curatedBlackTitle, detail: .curatedBlackDetail,
              url: "https://raw.githack.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS.txt"),
    ]
}

struct CuratedListsView: View {
    /// Called with the list's address; the caller imports it once this sheet has gone.
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.curatedLead.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Color.clear)
                ForEach(CuratedLists.all) { entry in
                    Section { row(entry) }
                        .signalFormRows()
                }
                Section {
                    Text(L10n.curatedSourceNote_fmt.formatted(CuratedLists.source))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Color.clear)
            }
            .signalFormChrome()
            .navigationTitle(L10n.addMenuCurated.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
    }

    private func row(_ entry: CuratedLists.Entry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(entry.title.localized())
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.detail.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OlcButton(L10n.curatedAddAction.localized(), systemImage: "plus.circle",
                      role: .secondary, fillWidth: true) {
                onPick(entry.url)
                dismiss()
            }
        }
        .padding(.vertical, Theme.Metrics.s2)
    }
}
