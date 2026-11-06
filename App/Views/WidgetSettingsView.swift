import SwiftUI
import UIKit

// MARK: - WidgetSettingsView
//
// Everything olcOS shows outside the app, and how to turn each off: the live
// card on the Lock Screen and in the Dynamic Island (a switch here), the
// widgets and the Control Centre button (added and removed the way iOS adds
// and removes every widget — the steps are spelled out), and iOS's own
// Live Activities switch for the app.

struct WidgetSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle(L10n.liveActivityToggle.localized(), isOn: $settings.liveActivity)
                TunnelSettingsNote(text: L10n.liveActivityNote.localized())
            } header: {
                SignalSectionHeader(L10n.widgetsLiveHeader.localized(), systemImage: "lock.iphone")
            }
            .signalFormRows()

            Section {
                TunnelSettingsNote(text: L10n.widgetsHomeHowTo.localized())
            } header: {
                SignalSectionHeader(L10n.widgetsHomeHeader.localized(), systemImage: "apps.iphone")
            }
            .signalFormRows()

            Section {
                TunnelSettingsNote(text: L10n.widgetsControlHowTo.localized())
            } header: {
                SignalSectionHeader(L10n.widgetsControlHeader.localized(), systemImage: "switch.2")
            }
            .signalFormRows()

            Section {
                Button(L10n.widgetsOpenSystemSettings.localized()) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                TunnelSettingsNote(text: L10n.widgetsSystemNote.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.settingsSectionWidgets.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}
