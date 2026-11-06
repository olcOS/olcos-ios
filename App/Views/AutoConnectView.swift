import SwiftUI

// MARK: - AutoConnectView
//
// Settings → Auto-connect: iOS turns the VPN on by itself on mobile data and
// on the Wi-Fi networks chosen here (VPNOnDemandPlan). It is a property of the
// system VPN, so it works only in VPN mode; the rules are saved with the VPN
// the next time it starts, and turning the VPN off by hand pauses them.

struct AutoConnectView: View {
    /// Says whether this install may run a VPN at all.
    @ObservedObject var vpn: VPNController
    @ObservedObject private var settings = SettingsStore.shared
    @State private var newNetwork = ""

    private var networks: [String] {
        VPNOnDemandPlan.cleaned(settings.vpnAutoNetworks.components(separatedBy: .newlines))
    }

    var body: some View {
        Form {
            if case .unavailable = vpn.capability {
                Section {
                    FormNote(text: L10n.autoConnectNeedsVPN.localized(), tone: .warn)
                }
                .signalFormRows()
            }
            Section {
                Toggle(isOn: $settings.vpnAutoCellular) {
                    Text(L10n.autoConnectCellular.localized())
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
            } footer: {
                Text(L10n.autoConnectLead.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .signalFormRows()

            Section {
                Picker(L10n.autoConnectWiFiHeader.localized(), selection: $settings.vpnAutoWiFi) {
                    ForEach(WiFiAutoConnect.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                SignalSectionHeader(L10n.autoConnectWiFiHeader.localized(), systemImage: "wifi")
            }
            .signalFormRows()

            if settings.vpnAutoWiFi.takesNetworks {
                networksSection
            }

            Section {
                FormNote(text: L10n.autoConnectKeyNote.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.autoConnectTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var networksSection: some View {
        Section {
            ForEach(networks, id: \.self) { name in
                Text(name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .onDelete { offsets in
                var list = networks
                list.remove(atOffsets: offsets)
                settings.vpnAutoNetworks = list.joined(separator: "\n")
            }
            HStack(spacing: Theme.Metrics.s2) {
                TextField(L10n.autoConnectNetworkPlaceholder.localized(), text: $newNetwork)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addNetwork)
                Button(L10n.autoConnectAddNetwork.localized(), action: addNetwork)
                    .font(Theme.Typography.bodyStrong)
                    .disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
        } header: {
            SignalSectionHeader(settings.vpnAutoWiFi == .only ? L10n.autoConnectOnlyHeader.localized()
                                                              : L10n.autoConnectExceptHeader.localized())
        } footer: {
            if networks.isEmpty, settings.vpnAutoWiFi == .only {
                Text(L10n.autoConnectNoNetworks.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .signalFormRows()
    }

    private func addNetwork() {
        let name = newNetwork.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        settings.vpnAutoNetworks = VPNOnDemandPlan.cleaned(networks + [name]).joined(separator: "\n")
        newNetwork = ""
    }
}
