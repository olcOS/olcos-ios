import SwiftUI

// MARK: - RoutingView
//
// Settings → Routing: every site through the tunnel, or the sites on a list
// straight from the phone and the rest through the tunnel. The list is the
// ready-made Russian one (DirectRoutes.russian) and the user's own lines.
// The engines take it when a session starts, so a change made while connected
// says so and offers to reconnect.

struct RoutingView: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject private var settings = SettingsStore.shared
    /// The user's lines as typed; saved on every change.
    @State private var draft = ""

    private var parsed: DirectRoutes.Parsed { DirectRoutes.parse(draft) }

    var body: some View {
        Form {
            modeSection
            if settings.routingMode == .listDirect {
                russianSection
                ownSection
            }
            if tunnel.state.isConnected {
                reconnectSection
            }
        }
        .signalFormChrome()
        .navigationTitle(L10n.routingTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = settings.routingOwnList }
        .onChange(of: draft) { _, text in
            if text != settings.routingOwnList { settings.routingOwnList = text }
        }
    }

    private var modeSection: some View {
        Section {
            Picker(L10n.routingTitle.localized(), selection: $settings.routingMode) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } footer: {
            Text(settings.routingMode == .allTunnel ? L10n.routingAllTunnelFooter.localized()
                                                    : L10n.routingListDirectFooter.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .signalFormRows()
    }

    private var russianSection: some View {
        Section {
            Toggle(isOn: $settings.routingRussianList) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(L10n.routingRussianList.localized())
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.routingRussianListDetail_fmt.formatted(DirectRoutes.russian.count))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
        }
        .signalFormRows()
    }

    private var ownSection: some View {
        Section {
            TextEditor(text: $draft)
                .font(Theme.Typography.mono)
                .frame(minHeight: 140)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel(L10n.routingOwnHeader.localized())
            if let bad = parsed.badLine {
                FormNote(text: L10n.routingBadLine_fmt.formatted(bad), tone: .warn)
            }
        } header: {
            SignalSectionHeader(L10n.routingOwnHeader.localized())
        } footer: {
            Text(L10n.routingOwnFooter.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .signalFormRows()
    }

    private var reconnectSection: some View {
        Section {
            FormNote(text: L10n.routingAppliesNext.localized())
            Button(L10n.routingReconnect.localized()) { reconnect() }
                .font(Theme.Typography.bodyStrong)
                .frame(minHeight: Theme.Metrics.controlHeight)
        }
        .signalFormRows()
    }

    /// The engines read the list when a session starts.
    private func reconnect() {
        guard let record = tunnel.connectedRecord else { return }
        tunnel.disconnect()
        tunnel.connect(record: record)
    }
}
