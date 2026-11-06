import SwiftUI
import WebKit

// MARK: - VKLoginView
//
// The ONE place a VK password is ever typed — and it is typed into VK's own
// page, never into a field of ours. This is the proven pattern from
// YandexLoginView, applied to VK: the human signs in ONCE in a real web view
// and the app then reuses the cookies that sign-in produced
// (VKSessionStore → VKCallRoomService).
//
// What this view is responsible for, and nothing else:
//   • load vk.ru as a desktop browser (VK's phone page is limited);
//   • poll `WKWebsiteDataStore.default().httpCookieStore` until the vk.ru jar
//     holds a `remixsid`, VERIFY the WHOLE jar against VK (a stale or guest
//     `remixsid` appears without any password typed) and hand the verified jar
//     back ONCE, then get out of the way;
//   • say what it is doing — a status line under the address bar — and offer
//     "Sign out of VK", so the user can always get rid of a web session the app
//     does not accept and switch accounts without leaving the page.
//
// It deliberately does NOT know where the credential is stored — the caller
// owns that (the Keychain, via VKSessionStore).
//
// SECURITY, in the order it matters:
//   • The warning line sits ABOVE the web view, so it is read BEFORE the
//     password is typed. `remixsid` is a bearer credential for the WHOLE VK
//     identity — messages, profile, VK Pay — usable without the password.
//   • The address is on screen: this view can follow a link anywhere, and a
//     password typed into an in-app web view whose URL nobody can see is a
//     phishing surface by construction.
//   • Unlike YandexLoginView, the web-view jar KEEPS the cookies after capture
//     (VKSessionStore.resolvedSession re-reads them as a fallback, and a still
//     valid jar means a re-open of this sheet signs in instantly). The forget
//     is still complete — "sign out" purges both copies (VKSessionStore.clear,
//     and this sheet's own button) — and it is the same completeness from the
//     other end: a session VK has rejected is cleared (cookies and Keychain
//     together), so opening this sheet again can only end in a real sign-in.
//   • The jar is never logged, never put in an error message and never held
//     anywhere but the callback; the only things written to the log are that a
//     session cookie was seen (or not) and how many cookies were involved. The
//     coordinator keeps one comparison key in memory (the session value plus
//     the cookie names) to avoid asking VK about the same jar twice.

/// What the sheet's status line tells the user about the page's sign-in.
enum VKSignInStatus: Equatable {
    /// No usable session cookie in the web view yet.
    case noSession
    /// A session cookie is there and VK is being asked whether it is a sign-in.
    case verifying
    /// VK answered: this is not a sign-in it accepts.
    case refused
    /// No usable answer (offline, an unreadable reply); the check is retried.
    case unreachable
}

/// PURE. When the sign-in sheet may ask VK about the cookie jar again.
///
/// The page changes cookies step by step while the user signs in, and every
/// ask is a request to VK — so a jar VK has refused is not asked about again
/// until it CHANGES, and no ask follows the previous one too closely.
enum VKSignInCheckPolicy {
    /// Rest after VK refused a jar. A changed jar is asked about only after it.
    static let refusedGap: TimeInterval = 3
    /// Rest after an attempt that got no usable answer. The same jar is
    /// retried, so the rest is longer — an offline phone does not hammer VK or
    /// fill the log.
    static let inconclusiveGap: TimeInterval = 10

    /// Whether to ask now. `key` is `VKSessionStore.signInKey(forJar:)`.
    static func shouldCheck(key: String, lastRefusedKey: String?,
                            notBefore: Date?, now: Date) -> Bool {
        if key == lastRefusedKey { return false }
        if let notBefore, now < notBefore { return false }
        return true
    }

    /// The earliest the next ask may start, given how this one ended.
    static func nextCheck(after verdict: AccountSessionVerdict, now: Date) -> Date? {
        switch verdict {
        case .alive:    return nil
        case .rejected: return now.addingTimeInterval(refusedGap)
        case .unknown:  return now.addingTimeInterval(inconclusiveGap)
        }
    }
}

struct VKLoginView: View {
    /// Called at most once, with the verified cookie jar (a `Cookie`-header
    /// string). The caller stores it (Keychain) — this view keeps no copy.
    let onSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Belt-and-braces against a re-created representable firing twice; the
    /// coordinator has its own guard.
    @State private var captured = false
    /// The host of the page currently on screen — the one thing that tells the
    /// user whether they are typing a password into VK or into wherever a link
    /// on the page took them.
    @State private var host = ""
    /// What the status line says.
    @State private var status: VKSignInStatus = .noSession
    /// Bumped by the toolbar's sign-out; the web view acts on a change.
    @State private var signOutTick = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                warning
                addressLine
                statusLine
                Divider()
                VKAuthWebView(signOutTick: signOutTick,
                              onHost: { host = $0 },
                              onStatus: { status = $0 }) { value in
                    guard !captured else { return }
                    captured = true
                    onSession(value)
                    dismiss()
                }
            }
            .navigationTitle(L10n.vkLoginTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel.localized()) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.vkLoginSignOutAction.localized()) {
                        status = .noSession
                        signOutTick += 1
                    }
                }
            }
        }
    }

    /// The one line the user must read before they type a password. Above the
    /// fold and above the web view on purpose — a warning shown after the
    /// credential exists is not a warning, it is a receipt.
    private var warning: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Theme.Palette.orange)
            Text(L10n.vkLoginWarning.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.vertical, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
    }

    /// The address bar: a `WKWebView` with no visible URL is indistinguishable
    /// from a page that only LOOKS like vk.ru. Host only — a full URL is
    /// unreadable at this width and would put query parameters into every
    /// screenshot. No `L10n` case, deliberately — a host name is data.
    private var addressLine: some View {
        HStack(spacing: Theme.Metrics.s2) {
            Image(systemName: "lock.fill")
            Text(host.isEmpty ? "…" : host)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.mono)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.bottom, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    /// What the app is doing about the page's sign-in. Without it a refused
    /// sign-in looks exactly like a sheet that is not working.
    private var statusLine: some View {
        HStack(spacing: Theme.Metrics.s2) {
            if status == .verifying {
                ProgressView().controlSize(.small)
            }
            Text(statusText)
                .font(Theme.Typography.caption)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.vertical, Theme.Metrics.s2)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch status {
        case .noSession:   return L10n.vkLoginStatusSignIn.localized()
        case .verifying:   return L10n.vkLoginStatusChecking.localized()
        case .refused:     return L10n.vkLoginStatusRefused.localized()
        case .unreachable: return L10n.vkErrNetwork.localized()
        }
    }

    private var statusColor: Color {
        switch status {
        case .noSession, .verifying: return Theme.Palette.textSecondary
        case .refused:               return Theme.Palette.red
        case .unreachable:           return Theme.Palette.orange
        }
    }
}

// MARK: - The web view

/// A plain `WKWebView` on the shared (persistent) data store, asked as a desktop
/// browser, plus a once-a-second cookie poll. No script injection and no
/// navigation interception — the cookies are the only reliable signal the
/// sign-in finished, so the cookies are what we watch.
private struct VKAuthWebView: UIViewRepresentable {
    /// VK's front page: signed out it shows the sign-in form, signed in it
    /// resolves straight to the feed — either way the session cookie is what
    /// marks the end of the flow.
    static let authURL = URL(string: "https://vk.ru/")!

    /// Changes when the toolbar's sign-out is tapped.
    let signOutTick: Int
    /// Called on every committed navigation with the host being displayed.
    let onHost: (String) -> Void
    /// Called when what the status line should say changes.
    let onStatus: (VKSignInStatus) -> Void
    let onSessionCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(signOutTick: signOutTick, onHost: onHost, onStatus: onStatus,
                    onSessionCookie: onSessionCookie)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The DEFAULT store is the one VK's own page writes into and the one
        // this view polls; a non-persistent store would mean a full sign-in
        // every single time.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = VKCallRoomService.desktopUserAgent
        web.navigationDelegate = context.coordinator
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
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Once a second: fast enough that the sheet closes as the redirect
        /// settles, slow enough to cost nothing.
        private static let pollSeconds: TimeInterval = 1

        var onSessionCookie: (String) -> Void
        var onHost: (String) -> Void
        var onStatus: (VKSignInStatus) -> Void
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
        /// that was already in flight cannot report a session the user has just
        /// thrown away (or cancelled).
        private var epoch = 0
        /// The `signInKey` of the last jar VK refused; not asked again until it
        /// changes (the real sign-in replacing a stale session is exactly that
        /// change). Held in memory only.
        private var lastRefusedKey: String?
        /// No ask before this moment (see `VKSignInCheckPolicy`).
        private var notBefore: Date?
        /// What the status line currently says, so the view hears only changes.
        private var shownStatus: VKSignInStatus = .noSession
        /// Whether the "no session cookie" diagnostic has been written for the
        /// current stretch without one — once, not once a second.
        private var loggedNoSession = false

        init(signOutTick: Int,
             onHost: @escaping (String) -> Void,
             onStatus: @escaping (VKSignInStatus) -> Void,
             onSessionCookie: @escaping (String) -> Void) {
            self.handledSignOutTick = signOutTick
            self.onHost = onHost
            self.onStatus = onStatus
            self.onSessionCookie = onSessionCookie
        }

        deinit { timer?.invalidate() }

        /// Report the host the moment the response that will be RENDERED is
        /// committed — the same moment a browser's address bar switches.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
        }

        /// Polling starts only after the first page has actually loaded. A user
        /// whose session is still valid is signed in the moment the page
        /// resolves — which is the right outcome — but they should SEE the page
        /// they asked for rather than watch a sheet flash open and shut.
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

        /// The toolbar's "Sign out of VK": forget the web session and what was
        /// refused, then load the page again once the cookies are really gone,
        /// so the sign-in form comes back and another account can be used.
        /// Nothing here calls into SwiftUI synchronously — the sheet has set
        /// its own status when the button was tapped.
        func signOut() {
            epoch &+= 1
            verifying = false
            signingOut = true
            lastRefusedKey = nil
            notBefore = nil
            shownStatus = .noSession
            loggedNoSession = false
            VKSessionStore.purgeWebCookies { [weak self] in
                guard let self else { return }
                self.signingOut = false
                self.webView?.load(URLRequest(url: VKAuthWebView.authURL))
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
                let vkCookies = cookies.filter { VKSessionStore.isVKDomain($0.domain) }.count
                self?.consider(VKSessionStore.sessionJar(in: cookies), vkCookieCount: vkCookies)
            }
        }

        /// What to do with the jar the poll just read. `vkCookieCount` is only
        /// for the log: how many vk.ru cookies the web view holds when none of
        /// them is a usable session.
        private func consider(_ jar: String?, vkCookieCount: Int) {
            guard !reported, !verifying, !signingOut else { return }
            guard let jar else {
                show(.noSession)
                noteNoSession(vkCookieCount)
                return
            }
            loggedNoSession = false
            let key = VKSessionStore.signInKey(forJar: jar)
            guard VKSignInCheckPolicy.shouldCheck(key: key, lastRefusedKey: lastRefusedKey,
                                                  notBefore: notBefore, now: Date()) else { return }
            verify(jar, key: key)
        }

        /// Ask VK whether the jar is a sign-in. A `remixsid` can be there
        /// without a password ever being typed, so presence proves nothing;
        /// only an accepted web_token exchange publishes the session.
        private func verify(_ jar: String, key: String) {
            verifying = true
            show(.verifying)
            let attempt = epoch
            let cookieCount = VKSessionStore.cookieCount(inJar: jar)
            Task { @MainActor [weak self] in
                LogStore.shared.log(.provisioning,
                    "VK sign-in sheet: session cookie seen, checking (\(cookieCount) cookies)")
                let verdict = await VKCallRoomService.sessionState(jar)
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

        private func show(_ status: VKSignInStatus) {
            guard status != shownStatus else { return }
            shownStatus = status
            onStatus(status)
        }

        /// Without this line a page that LOOKS signed in but yields no session
        /// cookie (the cookies live somewhere the app does not read) leaves the
        /// log empty, exactly like a refused sign-in used to. A count only —
        /// never a cookie name or value.
        private func noteNoSession(_ vkCookieCount: Int) {
            guard !loggedNoSession else { return }
            loggedNoSession = true
            Task { @MainActor in
                LogStore.shared.log(.provisioning,
                    "VK sign-in sheet: no session cookie yet (\(vkCookieCount) vk.ru cookies in the web view)")
            }
        }
    }
}

#if DEBUG
#Preview("VK sign-in — Dark") {
    VKLoginView { _ in }
        .preferredColorScheme(.dark)
}
#Preview("VK sign-in — Light") {
    VKLoginView { _ in }
        .preferredColorScheme(.light)
}
#endif
