import Foundation

// MARK: - VKCallRoom

/// A freshly created VK call.
///
/// Both halves are kept because both are wanted downstream: the server config
/// takes the full `https://vk.ru/call/join/<id>` link (`CarrierRoomInput` for
/// vkcalls normalizes to exactly that shape), while the UI shows it to the user
/// as the thing they would otherwise have copied out of the VK app.
struct VKCallRoom: Equatable, Sendable {
    /// `https://vk.ru/call/join/<id>` — the one shape the core accepts.
    let link: String
    /// `<id>` — the last path component.
    let id: String
}

// MARK: - VKCallRoomError

/// Everything that can go wrong creating a call, in the shape a view can ACT on:
/// sign in, wait, retry, or report. No case ever carries the session cookie, the
/// access token, the request headers or the response body — only a status code,
/// which is safe.
enum VKCallRoomError: LocalizedError, Equatable {
    /// No VK account has been linked yet — nothing to authenticate with.
    case noSession
    /// The saved `remixsid` is expired or revoked. The user must sign in again;
    /// there is nothing the app can retry.
    case sessionRejected
    /// VK is refusing the request for now — a flood/anti-robot gate or a
    /// per-second method limit. Waiting can fix it.
    case rateLimited
    /// The request never got an answer (offline, DNS poisoned, host blocked).
    case networkUnavailable
    /// A 2xx whose body is not the JSON we know how to read.
    case malformedResponse
    /// Any other HTTP status or VK error code, carried so the log and the alert
    /// can name it.
    case serviceError(status: Int)

    var errorDescription: String? {
        switch self {
        case .noSession:            return L10n.vkErrNoAccount.localized()
        case .sessionRejected:      return L10n.vkErrSessionRejected.localized()
        case .rateLimited:          return L10n.vkErrRateLimited.localized()
        case .networkUnavailable:   return L10n.vkErrNetwork.localized()
        case .malformedResponse:    return L10n.vkErrMalformed.localized()
        case .serviceError(let s):  return L10n.vkErrStatus_fmt.formatted(s)
        }
    }

    /// Whether the only way out is for the user to (re-)link a VK account —
    /// the view uses this to jump straight to the sign-in sheet instead of
    /// offering a pointless "retry".
    var needsSignIn: Bool {
        self == .noSession || self == .sessionRejected
    }
}

// MARK: - AccountSessionVerdict

/// What a session check actually established. "No answer" is deliberately
/// NOT a verdict: an offline phone must not be told its session is dead, and
/// a caller that unlinks on "dead" (the silent account check, the jar
/// fallback in the session stores) must be able to tell the three outcomes
/// apart. Shared by `VKCallRoomService` and `MTSLinkRoomService` — one
/// shape, two services.
enum AccountSessionVerdict: Equatable {
    /// The service answered for the credential and accepted it.
    case alive
    /// The service answered and refused THIS credential — sign in again.
    case rejected
    /// No answer, an unreadable answer, or a refusal that is not about the
    /// session. Not evidence either way.
    case unknown
}

// MARK: - VKCallRoomService
//
// One button's worth of API: create a fresh VK call from the phone, with the
// user's OWN VK account.
//
// Why the phone and not the VPS
// -----------------------------
// The same reason as TelemostRoomService: a room minted by the server is a room
// the phone can never learn again during a whitelist window. The phone creates
// the call and hands the link down the SSH path.
//
// The request chain
// -----------------
// VK's web client keeps its session in the `remixsid` cookie, but the method
// API (`api.vk.ru/method/*`) takes an OAuth-style bearer token. The chain the
// web client itself runs — and the one `kulikov0/whitelist-bypass` uses — is:
//
//   1. `login.vk.ru/?act=web_token` with the cookies — the WHOLE vk.ru jar
//      the browser holds, not `remixsid` alone (VKSessionStore) — hands back
//      `{"type":"okay","data":{"access_token":"…","user_id":…}}` — the token
//      of THIS session. Its refusals are the SAME envelope with
//      `type:"error"` and an `error_info` ("unauthorized" for a missing or
//      stale/GUEST session; "wrong origin" when the Origin header is not
//      exactly https://vk.ru).
//   2. `calls.start` mints the call — with NO `peer_id`: the production
//      reference (whitelist-bypass's vk-bot and Electron creator) launches it
//      parameterless and that is what works. Its `join_link` is a bare ~43
//      char id (never a URL), normalized to `https://vk.ru/call/join/<id>`
//      (`VKCallLink.fromJoinValue`).
//
// Anti-bot: a request without a browser User-Agent is answered HTTP 418 — the
// desktop UA below is load-bearing, not cosmetic.
//
// VK's method API is the web client's own, unofficial, and can change; every
// answer is parsed defensively and an unreadable body is an error, not a
// guessed success.
//
// Isolation: a nonisolated `enum` of statics, like every other stateless service
// here. Log lines hop to MainActor one at a time.

enum VKCallRoomService {

    // MARK: Endpoint

    /// The web-token exchange: the sign-in cookies become a method token.
    static let webTokenURL = URL(string: "https://login.vk.ru/?act=web_token")!

    /// The method API the web client calls.
    static let callsStartURL = URL(string: "https://api.vk.ru/method/calls.start")!

    /// A desktop browser: VK's phone pages and mobile API surface do not offer
    /// the same method calls. A desktop Safari — the client calls.vk.ru's own
    /// "Create meeting" accepts.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// The web client's own app id, sent by `?act=web_token`'s body — a literal
    /// of the flow, not a credential.
    private static let appID = "6287487"
    /// The method API version every call pins.
    private static let apiVersion = "5.282"

    private static let origin  = "https://vk.ru"
    private static let referer = "https://vk.ru/"

    /// Direct is a plain HTTPS round trip; the tunnel leg is a vp8/datachannel
    /// carrier and needs a longer rope for the same exchange.
    private static let directTimeout: TimeInterval = 20
    private static let tunnelTimeout: TimeInterval = 40

    // MARK: Create

    /// Creates a new VK call and returns its normalized link and bare id.
    ///
    /// Route: whatever the app is ALREADY using for VPS administration — the
    /// single policy of TelemostRoomService, copied, not reinvented: tunnel
    /// first when one is live (a direct HTTPS call can be cut during a whitelist
    /// window while the tunnel carries on), direct when none is. A transport
    /// failure retries once on the other route; an answer that actually arrived
    /// is never re-sent, except that a refusal received THROUGH the tunnel gets
    /// one direct retry — the same rule TelemostRoomService applies: the refusal
    /// may be about the exit's address.
    static func createRoom() async throws -> VKCallRoom {
        guard let session = await VKSessionStore.resolvedSession() else {
            await log("VK: cannot create a call — no VK account is linked")
            throw VKCallRoomError.noSession
        }

        let available = await SSHTransport.currentRoute()
        do {
            return try await createRoom(session: session, route: available)
        } catch VKCallRoomError.networkUnavailable {
            let fallback = SSHTransport.nextRoute(attempt: 2,
                                                  previous: available,
                                                  available: available)
            guard fallback != available else { throw VKCallRoomError.networkUnavailable }
            await log("VK: retrying call creation (route: \(fallback))")
            return try await createRoom(session: session, route: fallback)
        } catch VKCallRoomError.rateLimited where available.isTunnel {
            // The rule from TelemostRoomService: a refusal reached through
            // the tunnel is answered to the exit's datacenter address. A direct
            // path that is itself cut reports the ORIGINAL refusal.
            await log("VK: the refusal may be about the exit's address — retrying directly")
            do {
                return try await createRoom(session: session, route: .direct)
            } catch VKCallRoomError.networkUnavailable {
                throw VKCallRoomError.rateLimited
            }
        }
    }

    // MARK: Sign-in verification

    /// The diagnostic line for a check that got no answer at all (offline, a
    /// timeout, a non-2xx status — `send` has already logged which).
    static let signInCheckNoAnswerLine = "VK sign-in check: no answer"

    /// One web_token exchange with no side effects: true only when the
    /// credential yields a real access token.
    ///
    /// The sign-in sheet verifies the captured cookie jar with this before it
    /// hands it up: a jar that only LOOKS signed in — a stale web session, or a
    /// guest cookie the page set before any password was typed — answers
    /// "unauthorized", and an unverified adoption would link an account that
    /// can create nothing. Always direct: the sheet has no stake in the
    /// tunnel's route.
    static func sessionIsValid(_ session: String) async -> Bool {
        await sessionState(session) == .alive
    }

    /// The same exchange as a verdict, for callers that must not act on
    /// "no answer": the silent account check only unlinks a session the
    /// service has definitively refused.
    ///
    /// Every check leaves ONE log line saying what VK answered
    /// (`signInCheckLine`) — without it a refused sign-in is invisible in a
    /// shared log. The line never carries the credential or the token.
    static func sessionState(_ session: String) async -> AccountSessionVerdict {
        var req = URLRequest(url: webTokenURL, timeoutInterval: directTimeout)
        req.httpBody = Data("version=1&app_id=\(appID)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(VKSessionStore.cookieHeader(session: session), forHTTPHeaderField: "Cookie")
        let urlSession = SOCKSSession.make(mode: .direct, timeout: directTimeout)
        defer { urlSession.finishTasksAndInvalidate() }
        guard let data = try? await send(req, urlSession: urlSession, route: .direct) else {
            await log(signInCheckNoAnswerLine)
            return .unknown
        }
        await log(signInCheckLine(webTokenBody: data))
        return verdict(webTokenBody: data)
    }

    /// PURE. The one log line a web_token body earns: accepted, refused with
    /// VK's own short reason, or an answer that is neither (named with its
    /// size only — the body itself could carry account-scoped fields).
    static func signInCheckLine(webTokenBody data: Data) -> String {
        if let refusal = webTokenRefusal(in: data) {
            return "VK sign-in check: refused (\(diagnosticReason(refusal)))"
        }
        if let token = try? decodeAccessToken(data), !token.isEmpty {
            return "VK sign-in check: accepted"
        }
        return "\(signInCheckNoAnswerLine) (unreadable reply, \(data.count) bytes)"
    }

    /// PURE. A refusal reason cut down for the log: ASCII letters, digits,
    /// space and `_ . -`, at most 40 characters. VK's `error_info` is a short
    /// plain-English phrase ("unauthorized", "wrong origin"); control
    /// characters, markup, non-ASCII text or a runaway length never reach a log
    /// that users share.
    static func diagnosticReason(_ raw: String) -> String {
        var kept = ""
        var count = 0
        for scalar in raw.unicodeScalars where isReasonScalar(scalar) {
            kept.unicodeScalars.append(scalar)
            count += 1
            if count == 40 { break }
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "unspecified" : trimmed
    }

    private static func isReasonScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,   // 0-9 A-Z a-z
             0x20, 0x2D, 0x2E, 0x5F:                  // space - . _
            return true
        default:
            return false
        }
    }

    /// PURE. The verdict a web_token body carries, with no networking: the
    /// "unauthorized" refusal is a dead session; any OTHER refusal (the log
    /// names it — "wrong origin" is our bug, not the user's) and an unreadable
    /// body are no evidence either way.
    static func verdict(webTokenBody data: Data) -> AccountSessionVerdict {
        if let refusal = webTokenRefusal(in: data) {
            return error(forWebTokenRefusal: refusal) == .sessionRejected ? .rejected : .unknown
        }
        if let token = try? decodeAccessToken(data), !token.isEmpty { return .alive }
        return .unknown
    }

    /// The whole chain on one route. `session` is the stored credential (the
    /// vk.ru cookie jar) — it is written into ONE `Cookie` header and NOWHERE
    /// else (see the header note in `send`).
    private static func createRoom(session: String,
                                   route: SSHTransport.Route) async throws -> VKCallRoom {
        let timeout = route.isTunnel ? tunnelTimeout : directTimeout
        let urlSession = SOCKSSession.make(mode: route.isTunnel ? .tunnel : .direct,
                                           timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }

        let token = try await accessToken(session: session, urlSession: urlSession,
                                          timeout: timeout, route: route)
        return try await startCall(token: token, urlSession: urlSession,
                                   timeout: timeout, route: route)
    }

    // MARK: The three calls

    /// Step 1 — the sign-in cookies become the method token.
    private static func accessToken(session: String, urlSession: URLSession,
                                    timeout: TimeInterval,
                                    route: SSHTransport.Route) async throws -> String {
        var req = URLRequest(url: webTokenURL, timeoutInterval: timeout)
        req.httpBody = Data("version=1&app_id=\(appID)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(VKSessionStore.cookieHeader(session: session), forHTTPHeaderField: "Cookie")

        await log("VK: exchanging the session for an API token (route: \(route))")
        let data = try await send(req, urlSession: urlSession, route: route)
        // The login service answers its refusals as HTTP 200 with its own
        // envelope — probed live: a missing or GUEST cookie gets
        // "unauthorized", a missing Origin header gets "wrong origin".
        // Naming the refusal here is what turns "an answer the app could not
        // read" into the honest "sign in again".
        if let refusal = webTokenRefusal(in: data) {
            await log("VK: web_token refused the exchange (\(diagnosticReason(refusal)))")
            throw error(forWebTokenRefusal: refusal)
        }
        try await rejectAPIError(data, step: "web_token")

        do {
            return try decodeAccessToken(data)
        } catch {
            await log("VK: web_token answered with an unreadable body (\(data.count) bytes)")
            throw VKCallRoomError.malformedResponse
        }
    }

    /// Step 2 — the call itself. No `peer_id`: the production reference
    /// (whitelist-bypass's vk-bot and its Electron creator) launches
    /// `calls.start` parameterless, and the account id is already in the
    /// web_token answer should it ever be needed.
    private static func startCall(token: String, urlSession: URLSession,
                                  timeout: TimeInterval,
                                  route: SSHTransport.Route) async throws -> VKCallRoom {
        var req = URLRequest(url: callsStartURL, timeoutInterval: timeout)
        req.httpBody = Data("v=\(apiVersion)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        await log("VK: requesting a new call (route: \(route))")
        let data = try await send(req, urlSession: urlSession, route: route)
        try await rejectAPIError(data, step: "calls.start")

        let room = try await decodeOrLog(data)
        await log("VK: new call created — \(room.id)")
        return room
    }

    // MARK: Transport

    /// One POST on one route, shared by the three calls.
    ///
    /// `httpShouldHandleCookies` is OFF and the `Cookie` header is written by
    /// hand, so URLSession neither substitutes it from a jar nor persists the
    /// response's `Set-Cookie`. The access token travels in `Authorization` and
    /// neither value is ever logged: this function logs route, status and byte
    /// counts only.
    private static func send(_ base: URLRequest, urlSession: URLSession,
                             route: SSHTransport.Route) async throws -> Data {
        var req = base
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*",  forHTTPHeaderField: "Accept")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(referer, forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let error as URLError {
            // The URLError code is a system diagnostic, never anything of ours.
            await log("VK: no answer from the API (route: \(route), URLError \(error.code.rawValue))")
            throw VKCallRoomError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            await log("VK: the API answered with a non-HTTP response")
            throw VKCallRoomError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            await log("VK: the API returned HTTP \(http.statusCode)")
            throw error(forStatus: http.statusCode)
        }

        // A successful transfer through the tunnel counts as tunnel activity, so
        // keep-alive skips its next probe (same contract as IPChecker/SpeedTest).
        if route.isTunnel { SOCKSSession.noteTunnelActivity() }
        return data
    }

    // MARK: Pure parsing

    /// PURE. A VK error envelope's `error_code`, or nil when this body is not
    /// one. The method API answers HTTP 200 for its errors, so the status code
    /// alone never says whether the call happened.
    static func errorCode(in data: Data) -> Int? {
        (try? JSONDecoder().decode(VKErrorResponse.self, from: data))?.error?.errorCode
    }

    /// PURE. Decodes the web_token response: `{"data":{"access_token":"…"}}`.
    /// The value is a bearer credential — callers put it in a header and never
    /// in a log line or an error.
    static func decodeAccessToken(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(WebTokenResponse.self, from: data),
              let token = payload.data?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw VKCallRoomError.malformedResponse }
        return token
    }

    /// PURE. Decodes calls.start: `{"response":{"call_id":…,"join_link":…,
    /// "ok_join_link":…}}`. `join_link` wins, `ok_join_link` is the fallback;
    /// whatever value is picked must normalize to the one link shape the core
    /// accepts, else this body is `.malformedResponse` — a call we cannot name
    /// is not a call we can report.
    static func decodeCall(_ data: Data) throws -> VKCallRoom {
        guard let payload = try? JSONDecoder().decode(CallsStartResponse.self, from: data),
              let info = payload.response,
              let raw = info.joinLink?.trimmedNonEmpty ?? info.okJoinLink?.trimmedNonEmpty,
              let link = VKCallLink.fromJoinValue(raw),
              let id = link.split(separator: "/").last.map(String.init), !id.isEmpty
        else { throw VKCallRoomError.malformedResponse }
        return VKCallRoom(link: link, id: id)
    }

    /// PURE. The `error_info` of a web_token refusal, or nil when the body is
    /// not one. VK's login service answers its refusals as HTTP 200 with this
    /// envelope: `{"type":"error","error_code":"","error_info":"…"}` — probed
    /// live, "unauthorized" for a missing/guest cookie, "wrong origin" for a
    /// missing Origin header.
    static func webTokenRefusal(in data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(WebTokenErrorResponse.self, from: data),
              payload.type == "error",
              let info = payload.errorInfo?.trimmedNonEmpty
        else { return nil }
        return info
    }

    /// PURE. A web_token refusal to the action-shaped error: "unauthorized" is
    /// the guest-/no-cookie answer and means "sign in again"; any other
    /// `error_info` is exotic (the log line names it) and stays an unreadable
    /// answer rather than a guessed verdict.
    static func error(forWebTokenRefusal refusal: String) -> VKCallRoomError {
        refusal == "unauthorized" ? .sessionRejected : .malformedResponse
    }

    /// PURE. Maps a VK `error_code` to the action-shaped error. The codes are
    /// VK's own documented method-API codes: 5 is the invalid-session answer;
    /// 6/9/29 are the flood and per-second limits and 14 is captcha, where
    /// waiting is the only action the app can offer; 15 ("token required")
    /// means the token did not get ATTACHED — a client bug, not a sign-in
    /// problem — and everything else is reported by number.
    static func error(forErrorCode code: Int) -> VKCallRoomError {
        switch code {
        case 5:            return .sessionRejected
        case 6, 9, 14, 29: return .rateLimited
        default:           return .serviceError(status: code)
        }
    }

    /// PURE. Maps an HTTP status to the action-shaped error, the same split as
    /// TelemostRoomService: 401 is the credential, 403/429/503 are "wait and
    /// retry", the rest are named by number.
    static func error(forStatus status: Int) -> VKCallRoomError {
        switch status {
        case 401:            return .sessionRejected
        case 403, 429, 503:  return .rateLimited
        default:             return .serviceError(status: status)
        }
    }

    // MARK: Response envelopes

    private struct WebTokenResponse: Decodable {
        let data: TokenData?
        struct TokenData: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
    }

    private struct CallsStartResponse: Decodable {
        let response: CallInfo?
        struct CallInfo: Decodable {
            let callID: String?
            let joinLink: String?
            let okJoinLink: String?
            enum CodingKeys: String, CodingKey {
                case callID = "call_id"
                case joinLink = "join_link"
                case okJoinLink = "ok_join_link"
            }
        }
    }

    private struct VKErrorResponse: Decodable {
        let error: APIError?
        struct APIError: Decodable {
            let errorCode: Int?
            enum CodingKeys: String, CodingKey { case errorCode = "error_code" }
        }
    }

    /// web_token's refusal envelope — a DIFFERENT shape from the method API's
    /// `VKErrorResponse`: `error_code` arrives as a string (""), the reason
    /// lives in `error_info`.
    private struct WebTokenErrorResponse: Decodable {
        let type: String?
        let errorInfo: String?
        enum CodingKeys: String, CodingKey { case type; case errorInfo = "error_info" }
    }

    // MARK: Logging

    /// A 2xx body that carries VK's error envelope is a refusal, not a success:
    /// the method API answers HTTP 200 for its errors. The code is VK's own
    /// number and is safe to log; the body is never logged.
    private static func rejectAPIError(_ data: Data, step: String) async throws {
        guard let code = errorCode(in: data) else { return }
        await log("VK: \(step) answered with error code \(code)")
        throw error(forErrorCode: code)
    }

    private static func decodeOrLog(_ data: Data) async throws -> VKCallRoom {
        do {
            return try decodeCall(data)
        } catch {
            // Byte count only — the body could carry account-scoped fields.
            await log("VK: the API answered with an unreadable body (\(data.count) bytes)")
            throw VKCallRoomError.malformedResponse
        }
    }

    /// Every line here is engineering English and MUST stay free of the session
    /// cookie and the access token; `LogStore.log` also runs `redactSecrets` as
    /// a second net.
    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}

private extension String {
    /// Whitespace-trimmed, or nil when nothing is left.
    var trimmedNonEmpty: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
