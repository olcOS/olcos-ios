import SwiftUI

// MARK: - ServiceAccountsView
//
// Settings → Service accounts: what each call service needs before a server
// can sit in its rooms, and the accounts the app itself holds — Yandex (for
// Telemost rooms), VK (for VK calls) and MTS Link (for permanent meetings).
// Each linked account lets the app make that service's rooms by itself; every
// manual path stays listed as the fallback. SaluteJazz and Jitsi need nothing
// at all.
//
// Yandex and VK always offer a way out. The in-app web view keeps
// its own sign-in, so it can show an account as signed in while the Keychain
// holds nothing (a sign-in the app could not verify is never stored, and a
// Yandex sheet closed half-way leaves its cookies behind) — and with no stored
// session there is no "Sign out". "Reset sign-in in the browser" is that
// sign-out: it forgets the web view's session and any stored one.
//
// The three accounts are `ServiceAccountsSections`, which Settings shows in
// place as its Accounts group; this screen adds the services that need none.

struct ServiceAccountsView: View {
    var body: some View {
        Form {
            ServiceAccountsSections()

            Section {
                row(carrier: "salutejazz", status: L10n.addFlowNoAccount.localized(),
                    detail: L10n.accountsSaluteBody.localized())
                row(carrier: "jitsi", status: L10n.addFlowNoAccount.localized(),
                    detail: L10n.accountsJitsiBody.localized())
            } header: {
                SignalSectionHeader(L10n.accountsOthersHeader.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.accountsTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(carrier: String, status: String, detail: String) -> some View {
        ServiceAccountsSections.accountRow(carrier: carrier, status: status, detail: detail)
    }
}

/// Yandex, VK and MTS Link — one section each, the first under the Accounts
/// header — with every sign-in sheet and confirmation they open.
struct ServiceAccountsSections: View {
    @StateObject private var yandex = YandexSessionStore()
    @StateObject private var vk = VKSessionStore()
    @StateObject private var mts = MTSLinkSessionStore()
    @State private var showYandexLogin = false
    @State private var showVKLogin = false
    @State private var showMTSLogin = false
    /// The sign-in sheet in create mode, opened to show the app how a meeting
    /// is made; and whether it has been shown (a template exists).
    @State private var showMTSLesson = false
    @State private var mtsLearned = false
    @State private var confirmForgetMTS = false
    /// Which account a destructive sign-out is confirming
    /// ("vkcalls"/"mtslink").
    @State private var signOutTarget: String?
    /// Which account the browser reset is confirming
    /// ("telemost"/"vkcalls"/"mtslink").
    @State private var resetTarget: String?
    @State private var confirmYandexSignOut = false

    /// Each section carries the sheets and confirmations its own buttons open
    /// (a presentation on a row scrolled out of a long list may not show),
    /// and each refreshes on appearing.
    @ViewBuilder
    var body: some View {
        yandexPresentations(yandexSection)
            .onAppear { refresh() }
        vkPresentations(vkSection)
            .onAppear { refresh() }
        mtsPresentations(mtsSection)
            .onAppear { refresh() }
    }

    private func refresh() {
        yandex.refresh()
        vk.refresh()
        mts.refresh()
        mtsLearned = MTSLinkTemplateStore.current != nil
    }

    private var yandexSection: some View {
        Section {
            row(carrier: "telemost",
                status: yandex.hasSession ? L10n.accountSignedIn.localized()
                                          : L10n.accountSignedOut.localized(),
                detail: L10n.accountsYandexBody.localized())
            if yandex.hasSession {
                Button(L10n.accountsSignOutAction.localized(), role: .destructive) { confirmYandexSignOut = true }
            } else {
                Button(L10n.telemostRoomSignInAction.localized()) { showYandexLogin = true }
                Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "telemost" }
            }
        } header: {
            SignalSectionHeader(L10n.settingsGroupAccounts.localized())
        }
        .signalFormRows()
    }

    private var vkSection: some View {
        Section {
            row(carrier: "vkcalls",
                status: vk.hasSession ? L10n.accountSignedIn.localized()
                                      : L10n.accountSignedOut.localized(),
                detail: L10n.accountsVKBody.localized())
            if vk.hasSession {
                Button(L10n.signOutAction_fmt.formatted(CarrierTransportMatrix.carrierLabel("vkcalls")),
                       role: .destructive) { signOutTarget = "vkcalls" }
            } else {
                Button(L10n.vkSignInAction.localized()) { showVKLogin = true }
                Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "vkcalls" }
            }
        }
        .signalFormRows()
    }

    private var mtsSection: some View {
        Section {
            row(carrier: "mtslink",
                status: mts.hasSession ? L10n.accountSignedIn.localized()
                                       : L10n.accountSignedOut.localized(),
                detail: L10n.accountsMTSBody.localized())
            Text((mtsLearned ? L10n.mtsAccountLearned : L10n.mtsAccountNotLearned).localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(mtsLearned ? Theme.Palette.textSecondary : Theme.Palette.orange)
                .fixedSize(horizontal: false, vertical: true)
            if mts.hasSession {
                Button(L10n.signOutAction_fmt.formatted(CarrierTransportMatrix.carrierLabel("mtslink")),
                       role: .destructive) { signOutTarget = "mtslink" }
            } else {
                Button(L10n.mtsSignInAction.localized()) { showMTSLogin = true }
                Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "mtslink" }
            }
            Button(L10n.mtsTeachAction.localized()) { showMTSLesson = true }
            if mtsLearned {
                Button(L10n.mtsForgetAction.localized(), role: .destructive) { confirmForgetMTS = true }
            }
        }
        .signalFormRows()
    }

    // MARK: Presentations

    private func yandexPresentations(_ content: some View) -> some View {
        resetDialog(content, carrier: "telemost")
            .sheet(isPresented: $showYandexLogin) {
                YandexLoginView { session in
                    showYandexLogin = false
                    _ = yandex.save(session)
                }
            }
            .confirmationDialog(L10n.accountsSignOutTitle.localized(), isPresented: $confirmYandexSignOut,
                                titleVisibility: .visible) {
                Button(L10n.accountsSignOutAction.localized(), role: .destructive) { yandex.clear() }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: {
                Text(L10n.accountsSignOutMessage.localized())
            }
    }

    private func vkPresentations(_ content: some View) -> some View {
        resetDialog(signOutDialog(content, carrier: "vkcalls"), carrier: "vkcalls")
            .sheet(isPresented: $showVKLogin) {
                VKLoginView { session in
                    showVKLogin = false
                    _ = vk.save(session)
                }
            }
    }

    private func mtsPresentations(_ content: some View) -> some View {
        resetDialog(signOutDialog(content, carrier: "mtslink"), carrier: "mtslink")
            .fullScreenCover(isPresented: $showMTSLogin) {
                MTSLinkLoginView { session in
                    showMTSLogin = false
                    _ = mts.save(session)
                }
            }
            .fullScreenCover(isPresented: $showMTSLesson, onDismiss: {
                mts.refresh()
                mtsLearned = MTSLinkTemplateStore.current != nil
            }) {
                // Nothing takes the room here: the lesson is what matters.
                MTSLinkLoginView(onSession: { session in _ = mts.save(session) }, onRoom: { _ in })
            }
            .confirmationDialog(L10n.mtsForgetAction.localized(), isPresented: $confirmForgetMTS,
                                titleVisibility: .visible) {
                Button(L10n.mtsForgetAction.localized(), role: .destructive) {
                    MTSLinkTemplateStore.forget()
                    mtsLearned = false
                    LogStore.shared.log(.provisioning, "MTS Link: what the app learned about making rooms was forgotten")
                }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: {
                Text(L10n.mtsForgetMessage.localized())
            }
    }

    /// The sign-out confirmation of `carrier` ("vkcalls"/"mtslink").
    private func signOutDialog(_ content: some View, carrier: String) -> some View {
        let label = CarrierTransportMatrix.carrierLabel(carrier)
        return content.confirmationDialog(
            L10n.signOutConfirmTitle_fmt.formatted(label),
            isPresented: Binding(get: { signOutTarget == carrier },
                                 set: { if !$0 { signOutTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.signOutAction_fmt.formatted(label), role: .destructive) { clear(carrier) }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: {
            Text(L10n.signOutConfirmMessage_fmt.formatted(label))
        }
    }

    /// The browser-reset confirmation of `carrier`. `clear()` is the whole
    /// reset: the Keychain item (if any) and the web view's copy of the
    /// sign-in, so the next sign-in starts from scratch.
    private func resetDialog(_ content: some View, carrier: String) -> some View {
        let label = CarrierTransportMatrix.carrierLabel(carrier)
        return content.confirmationDialog(
            L10n.accountsResetBrowserTitle_fmt.formatted(label),
            isPresented: Binding(get: { resetTarget == carrier },
                                 set: { if !$0 { resetTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.accountsResetBrowserAction.localized(), role: .destructive) { clear(carrier) }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: {
            Text(L10n.accountsResetBrowserMessage_fmt.formatted(label))
        }
    }

    private func clear(_ carrier: String) {
        switch carrier {
        case "telemost": yandex.clear()
        case "vkcalls":  vk.clear()
        default:         mts.clear()
        }
    }

    private func row(carrier: String, status: String, detail: String) -> some View {
        Self.accountRow(carrier: carrier, status: status, detail: detail)
    }

    /// A service's name and state over one line on what it is for.
    static func accountRow(carrier: String, status: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            HStack {
                Text(CarrierTransportMatrix.carrierLabel(carrier))
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: Theme.Metrics.s2)
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Metrics.s1)
    }
}
