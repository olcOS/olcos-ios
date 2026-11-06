import SwiftUI
import WebKit

// MARK: - MTSLinkLoginView
//
// The ONE place an MTS Link password is ever typed — into MTS Link's own page,
// never into a field of ours. The pattern is VKLoginView's (itself
// YandexLoginView's): the human signs in ONCE in a real web view, the app
// lifts the cookies that sign-in produced and reuses them
// (MTSLinkSessionStore → MTSLinkRoomService).
//
// Besides the sign-in, this window does one more job: it WATCHES what the page
// does (MTSLinkHook: calls with their answers, the pages shown, the meeting
// links on them) and remembers it, scrubbed (MTSLinkRequestCapture). In CREATE
// mode (`onRoom` given) that is how the app learns how a meeting is made: the
// owner makes one permanent meeting by hand and presses Finish, and only then
// does the app analyse what this session recorded (MTSLinkLesson), check every
// meeting it found with the server's own first call (MTSLinkMeetingCheck),
// offer only the usable ones and — if one create call made a usable meeting
// unambiguously and the owner confirms — keep the call as a template that
// "Make a room" replays from inside the signed-in page (MTSLinkReplay). A
// quick meeting is refused with one line and teaches nothing. Nothing is
// learned, saved, returned or closed before Finish.
//
// The window is a full-screen page with one compact line above it (the
// address, the sign-in state, ⓘ) and, in create mode, one compact bar below.
// The long texts — the full cookie warning, how to teach the app, the sign-out,
// and the scrubbed "what the app saw" list with its copy-to-clipboard dump —
// sit behind ⓘ.
//
// SECURITY, in the order it matters:
//   • One line ABOVE the web view says the sign-in stays on this phone, so it
//     is read BEFORE the password is typed; the full warning is behind ⓘ. A
//     cabinet session is a bearer credential for the owner's whole MTS Link
//     identity — meetings, recordings, billing.
//   • The address is on screen: this view can follow a link anywhere, and a
//     password typed into an in-app web view whose URL nobody can see is a
//     phishing surface by construction.
//   • The jar is never logged and never held anywhere but the callback and
//     the Keychain. The capture stores no `Cookie` / `Authorization` /
//     `x-auth-token` value (MTSLinkRequestCapture scrubs them before anything
//     is kept) and the copy dump is that same scrubbed text.
//   • "Sign out of MTS Link" purges both copies of the session (the Keychain
//     item and the web view's cookies).

/// What the window tells the user about the page's sign-in.
enum MTSLinkSignInStatus: Equatable {
    /// No usable cookie jar in the web view yet.
    case noSession
    /// A jar is there and the cabinet is being asked whether it is a sign-in.
    case verifying
    /// The cabinet answered: this is not a sign-in it accepts.
    case refused
    /// No usable answer (offline, an unreadable reply); the check is retried.
    case unreachable
    /// The cabinet accepted the sign-in; it has been handed up.
    case signedIn
}

struct MTSLinkLoginView: View {
    /// Called with the verified cookie jar (a `Cookie`-header string). The
    /// caller stores it (Keychain) — this view keeps no copy. In create mode
    /// the window stays open afterwards.
    let onSession: (String) -> Void
    /// Create mode: called once, with the room the owner confirmed (or picked,
    /// or pasted), as `https://my.mts-link.ru/j/<owner>/<event>`; the window
    /// closes itself right after. nil = the plain sign-in window.
    let onRoom: ((String) -> Void)?
    /// Create mode: one line on why the window is open instead of a silent make
    /// (a replay failed, or the app has not learned yet).
    let reason: String?

    init(onSession: @escaping (String) -> Void, onRoom: ((String) -> Void)? = nil,
         reason: String? = nil) {
        self.onSession = onSession
        self.onRoom = onRoom
        self.reason = reason
    }

    /// Where the lesson stands.
    private enum Lesson: Equatable {
        case working
        /// The meetings Finish found, or a pasted link, are being checked.
        case checking
        /// Back to the page with this line: nothing usable, or a refused link.
        case refused(String)
        case confirm(MTSLinkMeeting)
        case pick(String, [MTSLinkMeeting])
    }

    private var createMode: Bool { onRoom != nil }

    @Environment(\.dismiss) private var dismiss
    @State private var lesson: Lesson = .working
    @State private var showInfo = false
    /// The room has been handed to the caller (once).
    @State private var delivered = false
    /// Belt-and-braces against a re-created representable firing twice.
    @State private var captured = false
    /// The host of the page currently on screen — the one thing that tells the
    /// user whether they are typing a password into MTS Link or into wherever a
    /// link on the page took them.
    @State private var host = ""
    /// What the sign-in mark says.
    @State private var status: MTSLinkSignInStatus = .noSession
    /// Bumped by the sign-out behind ⓘ; the web view acts on a change.
    @State private var signOutTick = 0
    /// What the page sent, scrubbed (MTSLinkRequestCapture).
    @StateObject private var capture = MTSLinkRequestCapture()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if status != .signedIn { noteRow(L10n.mtsLoginNote.localized(), color: Theme.Palette.textSecondary) }
            if status == .refused { noteRow(L10n.mtsLoginStatusRefused.localized(), color: Theme.Palette.red) }
            if status == .unreachable { noteRow(L10n.mtsErrNetwork.localized(), color: Theme.Palette.orange) }
            Divider()
            MTSLinkAuthWebView(capture: capture, signOutTick: signOutTick,
                               onHost: { host = $0 },
                               onStatus: { status = $0 }) { value in
                guard !captured else { return }
                captured = true
                status = .signedIn
                onSession(value)
                // The lesson is the owner's to end: a sign-in does not close it.
                if !createMode { dismiss() }
            }
            if createMode {
                Divider()
                lessonBar
            }
        }
        .sheet(isPresented: $showInfo) { infoSheet }
    }

    // MARK: The line above the page

    /// The address (a `WKWebView` with no visible URL is indistinguishable from
    /// a page that only LOOKS like my.mts-link.ru — host only, no `L10n` case:
    /// a host name is data), the sign-in mark and ⓘ. The plain sign-in window
    /// has no bar below, so its close button sits here.
    private var topBar: some View {
        HStack(spacing: Theme.Metrics.s2) {
            if !createMode {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel(L10n.closeAction.localized())
            }
            HStack(spacing: Theme.Metrics.s1) {
                Image(systemName: "lock.fill")
                Text(host.isEmpty ? "…" : host)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Palette.textSecondary)
            .accessibilityElement(children: .combine)
            statusMark
            Spacer(minLength: 0)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(L10n.mtsInfoTitle.localized())
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Metrics.s3)
        .padding(.vertical, Theme.Metrics.s1)
    }

    /// The sign-in state folded into the address line. Without it a refused
    /// sign-in looks exactly like a window that is not working.
    @ViewBuilder
    private var statusMark: some View {
        switch status {
        case .noSession:
            EmptyView()
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(statusText)
        case .signedIn:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.green)
                .accessibilityLabel(statusText)
        case .refused:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Palette.red)
                .accessibilityLabel(statusText)
        case .unreachable:
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.Palette.orange)
                .accessibilityLabel(statusText)
        }
    }

    private var statusText: String {
        switch status {
        case .noSession:   return L10n.mtsLoginStatusSignIn.localized()
        case .verifying:   return L10n.mtsLoginStatusChecking.localized()
        case .refused:     return L10n.mtsLoginStatusRefused.localized()
        case .unreachable: return L10n.mtsErrNetwork.localized()
        case .signedIn:    return L10n.accountSignedIn.localized()
        }
    }

    private var statusColor: Color {
        switch status {
        case .noSession, .verifying: return Theme.Palette.textSecondary
        case .signedIn:              return Theme.Palette.green
        case .refused:               return Theme.Palette.red
        case .unreachable:           return Theme.Palette.orange
        }
    }

    /// One short line under the address. The sign-in note stays until a
    /// sign-in is accepted: a warning shown after the credential exists is not
    /// a warning, it is a receipt.
    private func noteRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.s3)
            .padding(.bottom, Theme.Metrics.s1)
    }

    // MARK: Create mode: the bar below the page

    /// One line and one row of buttons. Cancel is always there, so the owner is
    /// never stuck; nothing below happens before he presses Finish.
    private var lessonBar: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            lessonLine
            if case .pick(_, let meetings) = lesson {
                ForEach(meetings) { meeting in
                    OlcButton(meeting.link, role: .secondary, fillWidth: true, compact: true) { usePicked(meeting) }
                }
            }
            HStack(spacing: Theme.Metrics.s2) {
                OlcButton(L10n.cancel.localized(), role: .ghost) { cancelLesson() }
                switch lesson {
                case .working, .refused:
                    OlcButton(nil, systemImage: "doc.on.clipboard", role: .secondary) { usePasted() }
                        .accessibilityLabel(L10n.pasteAction.localized())
                    OlcButton(L10n.mtsLearnFinish.localized(), systemImage: "checkmark.circle",
                              role: .primary, fillWidth: true) { finishLesson() }
                case .checking:
                    OlcButton(L10n.mtsLearnFinish.localized(), role: .primary,
                              isBusy: true, fillWidth: true) { }
                case .confirm(let meeting):
                    OlcButton(L10n.mtsLearnNotThis.localized(), role: .secondary) { rejectConfirmed(meeting) }
                    OlcButton(L10n.mtsLearnUse.localized(), systemImage: "checkmark",
                              role: .primary, fillWidth: true) { useConfirmed(meeting) }
                case .pick:
                    OlcButton(L10n.mtsLearnBack.localized(), role: .secondary, fillWidth: true) { lesson = .working }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.s3)
        .padding(.vertical, Theme.Metrics.s2)
        .background(Theme.Palette.orange.opacity(0.12))
    }

    @ViewBuilder
    private var lessonLine: some View {
        switch lesson {
        case .working:
            if let reason, !capture.meetingHint {
                barText(reason, color: Theme.Palette.orange)
            }
            barText(capture.meetingHint ? L10n.mtsLearnHint.localized() : L10n.mtsLearnStep.localized(),
                    color: capture.meetingHint ? Theme.Palette.orange : Theme.Palette.textPrimary)
        case .checking:
            HStack(spacing: Theme.Metrics.s2) {
                ProgressView().controlSize(.small)
                barText(L10n.mtsMeetingChecking.localized(), color: Theme.Palette.textSecondary)
            }
        case .refused(let text):
            barText(text, color: Theme.Palette.red)
        case .confirm(let meeting):
            barText(L10n.mtsLearnConfirm_fmt.formatted(meeting.link), color: Theme.Palette.textPrimary)
        case .pick(let text, _):
            barText(text, color: Theme.Palette.textPrimary)
        }
    }

    private func barText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Create mode: actions

    private func lessonLog(_ line: String) {
        capture.note(line)
        LogStore.shared.log(.provisioning, "MTS Link lesson: " + line)
    }

    /// Finish: only now does the app look at what this session recorded, and
    /// only meetings a server can enter are offered.
    private func finishLesson() {
        lessonLog("finished — \(capture.calls.count) calls, \(capture.sightings.count) page sightings recorded")
        let meetings: [MTSLinkMeeting]
        let ambiguous: Bool
        switch capture.analysis() {
        case .none:
            lessonLog("no meeting found")
            lesson = .refused(L10n.mtsLearnNone.localized())
            return
        case .one(let meeting):
            lessonLog("one meeting found (\(meeting.event)), \(meeting.madeByCall ? "made by a create call" : "only seen on the page")")
            meetings = [meeting]
            ambiguous = false
        case .several(let found):
            lessonLog("\(found.count) different meetings found (\(found.map(\.event).joined(separator: ", ")))")
            meetings = found
            ambiguous = true
        }
        lesson = .checking
        Task { @MainActor in
            var checked: [(meeting: MTSLinkMeeting, verdict: MTSLinkMeetingVerdict)] = []
            for meeting in meetings {
                let verdict = await MTSLinkMeetingCheck.check(link: meeting.link)
                lessonLog("meeting \(meeting.event): \(verdict.logText)")
                checked.append((meeting: meeting, verdict: verdict))
            }
            guard lesson == .checking, !delivered else { return }
            switch MTSLinkMeetingCheck.lessonGate(checked, ambiguous: ambiguous) {
            case .confirm(let meeting):
                lesson = .confirm(meeting)
            case .pick(let line, let usable):
                lessonLog("\(usable.count) usable meeting(s) to pick from — nothing is learned from a pick")
                lesson = .pick(line, usable)
            case .refused(let line):
                lessonLog("no usable meeting — nothing learned")
                lesson = .refused(line)
            }
        }
    }

    private func cancelLesson() {
        lessonLog("cancelled — nothing learned")
        dismiss()
    }

    /// "Use it": the one place a template is saved and the room returned. Only
    /// a meeting the check passed gets here.
    private func useConfirmed(_ meeting: MTSLinkMeeting) {
        var saved = false
        if let built = capture.template(for: meeting) {
            switch built {
            case .success(let template):
                MTSLinkTemplateStore.current = template
                saved = true
                lessonLog("template saved — " + template.shapeSummary)
            case .failure(let failure):
                lessonLog("no template: " + failure.reason)
            }
        }
        if meeting.madeByCall { MTSLinkCreatedRooms.remember(meeting.event) }
        lessonLog("confirmed meeting \(meeting.event) (template \(saved ? "saved" : "not saved"))")
        deliver(meeting.link)
    }

    private func rejectConfirmed(_ meeting: MTSLinkMeeting) {
        capture.dismiss(event: meeting.event)
        lessonLog("meeting \(meeting.event) rejected — back to the page")
        lesson = .working
    }

    /// A meeting picked from the list: no template is saved from an
    /// ambiguous lesson.
    private func usePicked(_ meeting: MTSLinkMeeting) {
        lessonLog("meeting \(meeting.event) picked from the list — no template saved")
        deliver(meeting.link)
    }

    /// The fallback that was always there: a meeting link from the clipboard,
    /// checked like any other.
    private func usePasted() {
        guard let link = MTSLinkRoom.plain(UIPasteboard.general.string ?? "") else {
            lesson = .refused(L10n.mtsLearnPasteInvalid.localized())
            return
        }
        lesson = .checking
        Task { @MainActor in
            let verdict = await MTSLinkMeetingCheck.check(link: link)
            guard lesson == .checking, !delivered else { return }
            if let refusal = verdict.refusal {
                lessonLog("a pasted link was refused — \(verdict.logText)")
                lesson = .refused(refusal)
                return
            }
            lessonLog("a pasted link was used — no template saved")
            deliver(link)
        }
    }

    private func deliver(_ link: String) {
        guard !delivered else { return }
        delivered = true
        onRoom?(link)
        dismiss()
    }

    // MARK: Behind ⓘ

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text(statusText)
                        .font(Theme.Typography.body)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.mtsLoginSignOutAction.localized(), role: .destructive) {
                        status = .noSession
                        captured = false
                        signOutTick += 1
                        showInfo = false
                    }
                }
                Section {
                    Text(L10n.mtsLoginWarning.localized())
                        .font(Theme.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if createMode {
                    Section {
                        Text(L10n.mtsLearnBanner.localized())
                            .font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text(L10n.mtsLearnBannerTitle.localized())
                    }
                }
                seenSection
            }
            .navigationTitle(L10n.mtsInfoTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done.localized()) { showInfo = false }
                }
            }
        }
    }

    /// "What the app saw": the scrubbed request list, the hint while there is
    /// nothing to show yet, and the copy-to-clipboard dump.
    private var seenSection: some View {
        Section {
            if capture.entries.isEmpty {
                Text(L10n.mtsSeenEmpty.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                // The one-time hint: what to do here so the app can learn how.
                Text(L10n.mtsSeenHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(capture.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(entry.id) \(entry.request.summary) → \(entry.status)")
                            .font(Theme.Typography.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let link = entry.newLink {
                            Text(link)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            if !capture.entries.isEmpty || !capture.sightings.isEmpty {
                Button(L10n.mtsSeenCopy.localized()) {
                    UIPasteboard.general.string = capture.dump()
                }
            }
        } header: {
            Text(L10n.mtsSeenTitle.localized())
        }
    }
}

// MARK: - The web view

/// A plain `WKWebView` on the shared (persistent) data store, presented as
/// desktop Chrome (MTSLinkDesktop), plus a once-a-second cookie poll and the
/// page-side hook (MTSLinkHook) that reports what the page does to
/// `MTSLinkRequestCapture`. Navigation is only touched to cancel links to an
/// app (MTSLinkDesktop.decide) — the cookies are the reliable signal the
/// sign-in finished, so the cookies are what we watch. Windows the page opens
/// load in this same view, and camera / microphone requests are denied.
private struct MTSLinkAuthWebView: UIViewRepresentable {
    /// The cabinet: signed out it shows the sign-in form, signed in it resolves
    /// to the account — either way the cookie jar marks the end of the flow.
    static let authURL = URL(string: "https://my.mts-link.ru/")!

    let capture: MTSLinkRequestCapture
    /// Changes when the sign-out behind ⓘ is tapped.
    let signOutTick: Int
    /// Called on every committed navigation with the host being displayed.
    let onHost: (String) -> Void
    /// Called when what the status line should say changes.
    let onStatus: (MTSLinkSignInStatus) -> Void
    let onSessionCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(capture: capture, signOutTick: signOutTick,
                    onHost: onHost, onStatus: onStatus, onSessionCookie: onSessionCookie)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The DEFAULT store is the one MTS Link's own page writes into and the
        // one this view polls; a non-persistent store would mean a full sign-in
        // every single time.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // The desktop page is laid out wider than a phone and shown scaled down;
        // pinch-zoom must work even where the page's viewport forbids scaling.
        config.ignoresViewportScaleLimits = true
        // A button that opens the meeting with window.open must be heard (the
        // UI delegate loads it in this same view).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(context.coordinator, name: MTSLinkHook.messageHandler)
        config.userContentController.addUserScript(WKUserScript(
            source: MTSLinkDesktop.shimScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(
            source: MTSLinkHook.script, injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = MTSLinkRoomService.desktopUserAgent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.webView = web
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.authURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Keep the callbacks fresh: `makeCoordinator` runs once, but the View
        // struct (and the closures it captured) is rebuilt on every render.
        let coordinator = context.coordinator
        coordinator.onSessionCookie = onSessionCookie
        coordinator.onHost = onHost
        coordinator.onStatus = onStatus
        if coordinator.handledSignOutTick != signOutTick {
            coordinator.handledSignOutTick = signOutTick
            coordinator.signOut()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: MTSLinkHook.messageHandler)
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        /// Once a second: fast enough that the sheet closes as the redirect
        /// settles, slow enough to cost nothing.
        private static let pollSeconds: TimeInterval = 1

        let capture: MTSLinkRequestCapture
        var onSessionCookie: (String) -> Void
        var onHost: (String) -> Void
        var onStatus: (MTSLinkSignInStatus) -> Void
        /// The sign-out tick this coordinator has already acted on.
        var handledSignOutTick: Int
        /// The page on screen.
        weak var webView: WKWebView?
        private var timer: Timer?
        private var reported = false
        /// One verification in flight — the poll does not stack requests on a
        /// jar that is still being checked.
        private var verifying = false
        /// Between a sign-out and the end of the cookie purge: the poll must
        /// not read a jar that is being deleted.
        private var signingOut = false
        /// Bumped by a sign-out and by the sheet going away, so a verification
        /// that was already in flight cannot report a session the user has
        /// just thrown away (or cancelled).
        private var epoch = 0
        /// The check key of the last jar the cabinet refused; not asked again
        /// until it changes. Held in memory only.
        private var lastRefusedKey: String?
        /// No ask before this moment (the VK sheet's policy, which speaks only
        /// of verdicts and is shared here on purpose).
        private var notBefore: Date?
        /// What the status line currently says, so the view hears only changes.
        private var shownStatus: MTSLinkSignInStatus = .noSession
        /// Whether the "no cookie yet" diagnostic is written for the current
        /// stretch without one — once, not once a second.
        private var loggedNoSession = false
        /// The camera / microphone requests already logged as denied.
        private var deniedMedia = Set<String>()

        init(capture: MTSLinkRequestCapture,
             signOutTick: Int,
             onHost: @escaping (String) -> Void,
             onStatus: @escaping (MTSLinkSignInStatus) -> Void,
             onSessionCookie: @escaping (String) -> Void) {
            self.capture = capture
            self.handledSignOutTick = signOutTick
            self.onHost = onHost
            self.onStatus = onStatus
            self.onSessionCookie = onSessionCookie
        }

        deinit { timer?.invalidate() }

        /// The page did something: remember it, scrubbed (the page replaced
        /// credential header values with provenance markers before sending,
        /// and the capture scrubs the rest). Nothing is decided here — the
        /// owner's Finish is.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == MTSLinkHook.messageHandler,
                  let body = message.body as? [String: Any] else { return }
            let kind = body["kind"] as? String ?? "req"
            if kind == "nav" {
                let url = body["url"] as? String ?? ""
                MainActor.assumeIsolated { capture.recordNavigation(url: url) }
                return
            }
            if kind == "page" {
                let links = body["links"] as? [String] ?? []
                MainActor.assumeIsolated { capture.recordPage(links: links) }
                return
            }
            let method = body["method"] as? String ?? "GET"
            let url = body["url"] as? String ?? ""
            let rawHeaders = body["headers"] as? [String: Any] ?? [:]
            var headers: [String: String] = [:]
            for (name, value) in rawHeaders {
                headers[name] = "\(value)"
            }
            let text = body["body"] as? String ?? ""
            let status = body["status"] as? Int ?? 0
            let response = body["response"] as? String ?? ""
            // WKScriptMessageHandler callbacks arrive on the main thread, so
            // the MainActor-isolated capture is reached directly — and in the
            // order the page sent the requests.
            // The page's own copy of the request, for the template (the scrubbed
            // one is made by the capture).
            let page = (body["tpl"] as? [String: Any]).flatMap {
                MTSLinkRawRequest.parse($0, headers: headers)
            }
            MainActor.assumeIsolated {
                capture.record(method: method, url: url, headers: headers,
                               body: text, status: status, response: response, page: page)
            }
        }

        /// Report the host the moment the response that will be RENDERED is
        /// committed — the same moment a browser's address bar switches.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
            note("page: " + MTSLinkDesktop.loggable(webView.url))
        }

        /// A link to an app (`mtslink:`, `intent:`, `itms-apps:`, `tel:`, an app
        /// store page) cannot be opened here: cancel it and keep the page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if case .blocked(let label) = MTSLinkDesktop.decide(navigationAction.request.url) {
                note(MTSLinkDesktop.blockedLine(label))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKUIDelegate

        /// `window.open` and `target=_blank` would be dropped without a handler:
        /// load the target in this same view instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let url = navigationAction.request.url
            if case .blocked(let label) = MTSLinkDesktop.decide(url) {
                note(MTSLinkDesktop.blockedLine(label))
            } else if MTSLinkDesktop.opensInSameView(url) {
                note(MTSLinkDesktop.newWindowLine(url))
                webView.load(navigationAction.request)
            } else {
                note("new window without a web address (" + MTSLinkDesktop.loggable(url) + ") — ignored")
            }
            return nil
        }

        /// The meeting room may ask for the camera and the microphone; the
        /// sheet never joins a call. Denied, and logged once per kind.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let kind: String
            switch type {
            case .camera:              kind = "camera"
            case .microphone:          kind = "microphone"
            case .cameraAndMicrophone: kind = "camera and microphone"
            @unknown default:          kind = "camera or microphone"
            }
            if deniedMedia.insert(kind).inserted {
                note("denied \(kind) request from \(origin.host)")
            }
            decisionHandler(.deny)
        }

        /// One diagnostic line, into the same log as the rest of the sheet.
        private func note(_ line: String) {
            Task { @MainActor in
                LogStore.shared.log(.provisioning, "MTS Link sign-in sheet: " + line)
            }
        }

        /// Polling starts only after the first page has actually loaded.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
            start()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// The sheet is going away (cancelled, or closed after a capture): stop
        /// polling and drop any verification still in flight.
        func invalidate() {
            epoch &+= 1
            stop()
        }

        /// "Sign out of MTS Link" behind ⓘ: forget the web session and what
        /// was refused, then load the page again once the cookies are really
        /// gone, ready for a new sign-in. Nothing here calls into SwiftUI
        /// synchronously.
        func signOut() {
            epoch &+= 1
            reported = false
            verifying = false
            signingOut = true
            lastRefusedKey = nil
            notBefore = nil
            shownStatus = .noSession
            loggedNoSession = false
            MTSLinkSessionStore.purgeWebCookies { [weak self] in
                guard let self else { return }
                self.signingOut = false
                self.webView?.load(URLRequest(url: MTSLinkAuthWebView.authURL))
            }
        }

        private func start() {
            guard timer == nil, !reported else { return }
            let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
                self?.poll()
            }
            // `.common` so the poll keeps running while the user is scrolling.
            RunLoop.main.add(t, forMode: .common)
            timer = t
            poll()
        }

        private func poll() {
            guard !reported, !verifying, !signingOut else { return }
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { [weak self] cookies in
                // The jar rule lives in the type that owns the credential —
                // one rule, no weaker copy here.
                let mtsCookies = cookies.filter { MTSLinkSessionStore.isMTSDomain($0.domain) }.count
                self?.consider(MTSLinkSessionStore.sessionJar(in: cookies), cookieCount: mtsCookies)
            }
        }

        /// What to do with the jar the poll just read. `cookieCount` is only
        /// for the log: how many mts-link.ru cookies the web view holds when
        /// none of them is a usable jar.
        private func consider(_ jar: String?, cookieCount: Int) {
            guard !reported, !verifying, !signingOut else { return }
            guard let jar else {
                show(.noSession)
                noteNoSession(cookieCount)
                return
            }
            loggedNoSession = false
            let key = MTSLinkSessionStore.signInKey(forJar: jar)
            guard VKSignInCheckPolicy.shouldCheck(key: key, lastRefusedKey: lastRefusedKey,
                                                  notBefore: notBefore, now: Date()) else { return }
            verify(jar, key: key)
        }

        /// Ask the cabinet whether the jar is a sign-in. Cookies can be there
        /// without a password ever being typed (an anonymous visit sets some
        /// too), so presence proves nothing; only an accepted check publishes
        /// the session.
        private func verify(_ jar: String, key: String) {
            verifying = true
            show(.verifying)
            let attempt = epoch
            let cookieCount = MTSLinkSessionStore.cookieCount(inJar: jar)
            Task { @MainActor [weak self] in
                LogStore.shared.log(.provisioning,
                    "MTS Link sign-in sheet: cookies seen, checking (\(cookieCount) cookies)")
                let verdict = await MTSLinkRoomService.sessionState(jar)
                guard let self, self.epoch == attempt, !self.reported else { return }
                self.verifying = false
                self.finish(verdict, jar: jar, key: key)
            }
        }

        private func finish(_ verdict: AccountSessionVerdict, jar: String, key: String) {
            notBefore = VKSignInCheckPolicy.nextCheck(after: verdict, now: Date())
            switch verdict {
            case .alive:
                reported = true
                stop()
                onSessionCookie(jar)
            case .rejected:
                lastRefusedKey = key
                show(.refused)
            case .unknown:
                show(.unreachable)
            }
        }

        private func show(_ status: MTSLinkSignInStatus) {
            guard status != shownStatus else { return }
            shownStatus = status
            onStatus(status)
        }

        /// Without this line a page that LOOKS signed in but yields no cookie
        /// leaves the log empty, exactly like a refused sign-in. A count only —
        /// never a cookie name or value.
        private func noteNoSession(_ cookieCount: Int) {
            guard !loggedNoSession else { return }
            loggedNoSession = true
            Task { @MainActor in
                LogStore.shared.log(.provisioning,
                    "MTS Link sign-in sheet: no cookies yet (\(cookieCount) mts-link.ru cookies in the web view)")
            }
        }
    }
}
