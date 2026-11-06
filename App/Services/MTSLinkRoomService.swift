import Foundation

// MARK: - MTSLinkRoomError

/// Everything that can go wrong making a meeting, in the shape a view can ACT
/// on: sign in, wait, retry, or report. No case ever carries the session
/// cookies, a request header or a response body — only a status code, which
/// is safe.
enum MTSLinkRoomError: LocalizedError, Equatable {
    /// No MTS Link account has been linked yet — nothing to authenticate with.
    case noSession
    /// The saved cookies are expired or revoked. The user must sign in again.
    case sessionRejected
    /// The app has not learned how the service makes a meeting yet (no
    /// template) — there is nothing to replay. The sheet's lesson or the pasted
    /// link is the way.
    case noCreateRequest
    /// MTS Link is refusing the request for now. Waiting can fix it.
    case rateLimited
    /// The request never got an answer (offline, DNS poisoned, host blocked).
    case networkUnavailable
    /// A 2xx whose body carries no meeting link the app can read.
    case malformedResponse
    /// Any other HTTP status, carried so the log and the alert can name it.
    case serviceError(status: Int)
    /// A header of the learned request needs a token the page did not give
    /// the app (the header's NAME, never a value). Nothing was sent.
    case missingToken(String)
    /// The service answered with the room that is already current — most
    /// likely the plan's cap on permanent meetings.
    case sameRoom
    /// The replay did not finish in time.
    case timedOut
    /// The service answered 401 or 403 to the replayed request. Treated as a
    /// sign-in problem, but the status and the (scrubbed, one-line) head of its
    /// answer travel with it, so a refusal for the plan's limit of permanent
    /// meetings reads differently from a lost sign-in.
    case rejected(status: Int, head: String)
    /// The meeting is not one the server can enter (MTSLinkMeetingCheck): a
    /// quick meeting, no session, unknown to the service, or not checkable.
    case unusableMeeting(MTSLinkMeetingVerdict)

    var errorDescription: String? {
        switch self {
        case .noSession:           return L10n.mtsErrNoAccount.localized()
        case .sessionRejected:     return L10n.mtsErrSessionRejected.localized()
        case .noCreateRequest:     return L10n.mtsErrNoCreateRequest.localized()
        case .rateLimited:         return L10n.mtsErrRateLimited.localized()
        case .networkUnavailable:  return L10n.mtsErrNetwork.localized()
        case .malformedResponse:   return L10n.mtsErrMalformed.localized()
        case .serviceError(let s): return L10n.mtsErrStatus_fmt.formatted(s)
        case .missingToken:        return L10n.mtsErrMissingToken.localized()
        case .sameRoom:            return L10n.mtsErrSameRoom.localized()
        case .timedOut:            return L10n.mtsErrTimeout.localized()
        case .rejected(let status, let head):
            return L10n.mtsErrRejected_fmt.formatted(status, head.isEmpty ? "—" : head)
        case .unusableMeeting(let verdict):
            return verdict.refusal ?? L10n.mtsMeetingUnknown.localized()
        }
    }

    /// Engineering English for the log: what happened, no value in it.
    var logText: String {
        switch self {
        case .noSession:           return "no account is linked"
        case .sessionRejected:     return "signed out or refused (HTTP 401/403)"
        case .noCreateRequest:     return "the app has not learned how yet"
        case .rateLimited:         return "the service is refusing new meetings (HTTP 429/503)"
        case .networkUnavailable:  return "no answer from the page"
        case .malformedResponse:   return "the answer carries no meeting the template can read"
        case .serviceError(let s): return "HTTP \(s)"
        case .missingToken(let n): return "no value for the header \(n)"
        case .sameRoom:            return "the answer is the room that is already current"
        case .timedOut:            return "timed out"
        case .rejected(let s, _):  return "HTTP \(s) (signed out, or the plan's limit of permanent meetings)"
        case .unusableMeeting(let v): return "the meeting is not usable (\(v.logText))"
        }
    }
    /// Whether the only way out is for the user to (re-)link an account — the
    /// view uses this to jump straight to the sign-in sheet instead of
    /// offering a pointless "retry".
    var needsSignIn: Bool {
        switch self {
        case .noSession, .sessionRejected, .rejected: return true
        default:                                       return false
        }
    }
}

// MARK: - MTSLinkRoomService
//
// What the app asks of the MTS Link account around making a meeting. The
// meeting itself is made by replaying, from inside the signed-in page, the
// request the owner showed the app in a lesson (MTSLinkTemplate); this enum
// holds the constants, the "can the app make a room" gate, the room-id helper
// and the sign-in check.
//
// Isolation: a nonisolated `enum` of statics, like every other stateless
// service here. Log lines hop to MainActor one at a time.

enum MTSLinkRoomService {

    // MARK: Endpoints

    /// The cabinet page: the origin the core itself names as the web client's
    /// page (olcrtc-upstream internal/auth/mtslink, `webOrigin`). Used for the
    /// sign-in check and as the page a replay runs in.
    static let webOrigin = URL(string: "https://my.mts-link.ru/")!

    /// Desktop Chrome on Windows: the cabinet is a desktop-first web app. The one
    /// identity of the sign-in sheet and of the offscreen replay page, so both
    /// look the same to the site (see MTSLinkDesktop for the rest of the disguise).
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private static let directTimeout: TimeInterval = 20

    /// Whether the app can make a meeting by itself: it has learned how
    /// (a confirmed template) and holds the saved sign-in. Gates the one-button
    /// path of "Make a room" and MTS Link's room auto-update rule.
    static var canCreateRooms: Bool {
        MTSLinkTemplateStore.current != nil && MTSLinkSessionStore.hasStoredSession()
    }

    // MARK: Create

    /// PURE. The event id of a normalized meeting link — the last path part.
    static func eventId(of link: String) -> String? {
        let plain = MTSLinkRoom.plain(link) ?? link
        guard let id = plain.split(separator: "/").last, !id.isEmpty else { return nil }
        return String(id)
    }

    /// Makes a new permanent meeting by replaying, from inside the signed-in
    /// page, the request the owner showed the app (MTSLinkReplay). `current` is
    /// the room that is current: an answer equal to it is a failure. Throws
    /// `MTSLinkRoomError`; the callers fall back to the sign-in sheet in create
    /// mode (MTSLinkRoomMaker).
    static func createRoom(current: String = "") async throws -> String {
        guard MTSLinkSessionStore.hasStoredSession() else {
            await log("MTS Link: cannot make a room — no account is linked")
            throw MTSLinkRoomError.noSession
        }
        guard let template = MTSLinkTemplateStore.current else {
            await log("MTS Link: cannot make a room — the app has not learned how yet")
            throw MTSLinkRoomError.noCreateRequest
        }
        switch await MTSLinkReplay.run(template: template, current: current) {
        case .success(let room):
            // The meeting the template made must be one the server can enter.
            let verdict = await MTSLinkMeetingCheck.checkFresh(link: room)
            switch MTSLinkMeetingCheck.replayAction(verdict) {
            case .use:
                return room
            case .dropTemplate:
                MTSLinkTemplateStore.current = nil
                await log("MTS Link replay: the new meeting is \(verdict.logText) — the saved template makes the wrong kind of meeting and was forgotten; the next make runs the lesson again")
            case .fail:
                await log("MTS Link replay: the new meeting \(verdict.logText) — not used")
            }
            throw MTSLinkRoomError.unusableMeeting(verdict)
        case .failure(let error):
            await log("MTS Link replay: failed — \(error.logText)")
            throw error
        }
    }

    /// One line, in the user's language, for why the sign-in sheet opens in
    /// create mode without a replay having failed.
    static func lessonReason() -> String {
        (MTSLinkSessionStore.hasStoredSession() ? L10n.mtsReasonLearn : L10n.mtsReasonSignIn).localized()
    }
    // MARK: Sign-in verification

    /// The diagnostic line for a check that got no answer at all (offline, a
    /// timeout, a non-2xx status — `send` has already logged which).
    static let signInCheckNoAnswerLine = "MTS Link sign-in check: no answer"

    /// One side-effect-free look at the saved session: true only when the
    /// cabinet still answers for it. The sign-in sheet verifies the captured
    /// jar with this before it hands it up.
    static func sessionIsValid(_ session: String) async -> Bool {
        await sessionState(session) == .alive
    }

    /// The same look as a verdict, for callers that must not act on "no
    /// answer" (the silent daily account check only unlinks a session the
    /// service has DEFINITIVELY refused).
    ///
    /// What it can and cannot know: there is no account API the app may call —
    /// the create request is the owner's own page request, and replaying it
    /// here would MAKE a meeting. So the check reads the cabinet page itself:
    /// a 401/403, or a page that resolves to a sign-in form, is the service
    /// refusing THIS credential; anything else is weak evidence at best, and
    /// an unreadable answer is no evidence at all. Every check leaves ONE log
    /// line (`signInCheckLine`) — never the credential.
    static func sessionState(_ session: String) async -> AccountSessionVerdict {
        var req = URLRequest(url: webOrigin, timeoutInterval: directTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(MTSLinkSessionStore.cookieHeader(session: session),
                     forHTTPHeaderField: "Cookie")
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let urlSession = SOCKSSession.make(mode: .direct, timeout: directTimeout)
        defer { urlSession.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(req, urlSession: urlSession, route: .direct)
        } catch {
            await log(signInCheckNoAnswerLine)
            return .unknown
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        let verdict = self.verdict(status: status,
                                   finalURL: response.url?.absoluteString ?? "",
                                   body: body)
        await log(signInCheckLine(verdict, status: status))
        return verdict
    }

    /// PURE. The verdict the cabinet page's answer carries, with no networking.
    static func verdict(status: Int, finalURL: String, body: String) -> AccountSessionVerdict {
        switch status {
        case 401, 403:
            return .rejected
        case 200..<300:
            return showsSignInPage(finalURL: finalURL, body: body) ? .rejected : .alive
        default:
            return .unknown
        }
    }

    /// PURE. A page that offers a password field, or resolves to a sign-in
    /// URL, is the cabinet asking "who are you?" — this session is gone.
    static func showsSignInPage(finalURL: String, body: String) -> Bool {
        let url = finalURL.lowercased()
        for marker in ["/login", "/signin", "/sign-in", "/auth", "/sso"] {
            if url.contains(marker) { return true }
        }
        let lower = body.lowercased()
        return lower.contains("type=\"password\"") || lower.contains("type='password'")
    }

    /// PURE. The one log line a check earns. Never the credential.
    static func signInCheckLine(_ verdict: AccountSessionVerdict, status: Int) -> String {
        switch verdict {
        case .alive:    return "MTS Link sign-in check: accepted"
        case .rejected: return "MTS Link sign-in check: refused (HTTP \(status))"
        case .unknown:  return "\(signInCheckNoAnswerLine) (HTTP \(status))"
        }
    }

    // MARK: Transport

    /// One call on one route. `httpShouldHandleCookies` is OFF and the `Cookie`
    /// header is written by hand (the saved jar), so URLSession neither
    /// substitutes one from a jar nor persists the response's `Set-Cookie`. The
    /// jar travels in that header and NOWHERE else: this function logs route,
    /// status and byte counts only.
    private static func send(_ req: URLRequest, urlSession: URLSession,
                             route: SSHTransport.Route) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: req)
            // A successful transfer through the tunnel counts as tunnel
            // activity, so keep-alive skips its next probe.
            if route.isTunnel { SOCKSSession.noteTunnelActivity() }
            return (data, response)
        } catch let error as URLError {
            await log("MTS Link: no answer from the service (route: \(route), URLError \(error.code.rawValue))")
            throw MTSLinkRoomError.networkUnavailable
        }
    }

    /// Every line here is engineering English and MUST stay free of the cookie
    /// jar; `LogStore.log` also runs `redactSecrets` as a second net.
    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}
