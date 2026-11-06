import Foundation

// MARK: - MTSLinkMeetingVerdict

/// What the event's public record says about a meeting, in the terms of what
/// the server can do with it.
enum MTSLinkMeetingVerdict: Equatable, Sendable {
    /// An endless (permanent) meeting with a session: a guest can enter it
    /// with nobody inside. The session is the one the core will take.
    case usable(sessionID: Int64)
    /// A quick or scheduled meeting: it runs only while someone is in it.
    case notPermanent
    /// Endless, but without a session to enter.
    case noSession
    /// The service does not know the meeting (HTTP 404 / 406 / 410).
    case gone
    /// No usable answer: offline, another status, an unreadable record.
    case unknown

    var isUsable: Bool {
        if case .usable = self { return true }
        return false
    }

    /// The one line the person reads; nil for a usable meeting.
    var refusal: String? {
        switch self {
        case .usable:       return nil
        case .notPermanent: return L10n.mtsMeetingQuick.localized()
        case .noSession:    return L10n.mtsMeetingNoSession.localized()
        case .gone:         return L10n.mtsMeetingGone.localized()
        case .unknown:      return L10n.mtsMeetingUnknown.localized()
        }
    }

    /// Engineering English for the log.
    var logText: String {
        switch self {
        case .usable(let id): return "permanent, session \(id)"
        case .notPermanent:   return "not a permanent meeting"
        case .noSession:      return "permanent, but no session"
        case .gone:           return "unknown to the service"
        case .unknown:        return "could not be checked"
        }
    }
}

// MARK: - MTSLinkMeetingCheck
//
// A meeting is checked before it is used, with the call the server itself
// makes first: the event's public record (olcrtc-upstream
// internal/auth/mtslink, `eventSession`) — `GET <gateway>/api/event/<id>`, no
// cookies, the web client's Origin and Referer, a desktop browser. The core
// takes the first session of that record and joins it as a guest; only an
// endless meeting has one from the moment it is made, so only an endless
// meeting with a session is passed on. Nothing else of the service is called.
//
// Every path that hands an MTS Link room to a server runs through it: the
// lesson's Finish, the one-button make, a pasted link, and the Provisioner
// install / add-protocol / reconfigure operations (room rotation included).
enum MTSLinkMeetingCheck {

    static let gateway = "https://gw.mts-link.ru"
    static let webOrigin = "https://my.mts-link.ru"
    static let timeout: TimeInterval = 10
    /// A meeting made a moment ago is asked again this many times, this far
    /// apart, while the answer is "no session" or no answer at all.
    static let freshAttempts = 3
    static let freshPause: TimeInterval = 2

    // MARK: Pure

    /// PURE. The event id of a meeting link, or nil when it is not one.
    static func event(of link: String) -> String? {
        MTSLinkRoom.event(of: link)
    }

    /// PURE. The core's event lookup for `event`; nil for anything that is not
    /// a service id.
    static func request(event: String) -> URLRequest? {
        guard MTSLinkRoom.isID(event), let url = URL(string: gateway + "/api/event/" + event) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(MTSLinkRoomService.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(webOrigin, forHTTPHeaderField: "Origin")
        req.setValue(webOrigin + "/", forHTTPHeaderField: "Referer")
        return req
    }

    /// PURE. The verdict the record carries. Mirrors the core: 404 / 406 / 410
    /// are a room the service does not have, only a 200 is an answer, and the
    /// first session is taken whatever its status.
    static func verdict(status: Int, body: Data) -> MTSLinkMeetingVerdict {
        switch status {
        case 404, 406, 410: return .gone
        case 200:           break
        default:            return .unknown
        }
        guard let record = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .unknown }
        guard let endless = record["isEndless"] as? Bool, endless else { return .notPermanent }
        guard let sessions = record["eventSessions"] as? [Any],
              let first = sessions.first as? [String: Any],
              let id = first["id"] as? NSNumber,
              CFGetTypeID(id) != CFBooleanGetTypeID(),
              id.int64Value > 0 else { return .noSession }
        return .usable(sessionID: id.int64Value)
    }

    /// PURE. The MTS Link rooms among `options` — the ones to check.
    static func roomsToCheck(_ options: [InstallOptions]) -> [String] {
        options.filter { $0.carrier == "mtslink" }.map(\.roomID)
    }

    /// What the lesson's Finish offers once its meetings are checked.
    enum LessonGate: Equatable {
        /// One usable meeting from an unambiguous lesson: confirm it (and
        /// learn from it when a create call made it).
        case confirm(MTSLinkMeeting)
        /// Pick one of these; nothing is learned from a pick.
        case pick(String, [MTSLinkMeeting])
        /// Nothing usable: this line, and back to the page.
        case refused(String)
    }

    /// PURE. Only usable meetings are offered. A meeting the lesson MADE that
    /// is not usable (a quick meeting) is never confirmed, so no template is
    /// learned from it; usable meetings the page showed may still be picked.
    static func lessonGate(_ checked: [(meeting: MTSLinkMeeting, verdict: MTSLinkMeetingVerdict)],
                           ambiguous: Bool) -> LessonGate {
        guard let lead = checked.first(where: { $0.meeting.madeByCall }) ?? checked.first else {
            return .refused(L10n.mtsLearnNone.localized())
        }
        let usable = checked.filter { $0.verdict.isUsable }.map(\.meeting)
        if usable.isEmpty {
            return .refused(lead.verdict.refusal ?? L10n.mtsMeetingUnknown.localized())
        }
        if lead.meeting.madeByCall, let line = lead.verdict.refusal {
            return .pick(line, usable)
        }
        if ambiguous || usable.count > 1 {
            return .pick(L10n.mtsLearnSeveral.localized(), usable)
        }
        return .confirm(usable[0])
    }

    /// What the one-button make does with the meeting it made.
    enum ReplayAction: Equatable {
        case use
        /// The template makes a meeting the server cannot enter: forget it.
        case dropTemplate
        /// No answer: keep the template, use nothing.
        case fail
    }

    /// PURE.
    static func replayAction(_ verdict: MTSLinkMeetingVerdict) -> ReplayAction {
        switch verdict {
        case .usable:                         return .use
        case .notPermanent, .noSession, .gone: return .dropTemplate
        case .unknown:                        return .fail
        }
    }

    /// PURE. Whether a meeting made a moment ago is worth asking about again.
    static func worthAskingAgain(_ verdict: MTSLinkMeetingVerdict) -> Bool {
        verdict == .noSession || verdict == .unknown
    }

    // MARK: The call

    /// One look at the meeting behind `link`. Leaves one log line.
    static func check(link: String) async -> MTSLinkMeetingVerdict {
        guard let id = Self.event(of: link), let req = request(event: id) else {
            await log("MTS Link meeting check: not a meeting link")
            return .unknown
        }
        let session = SOCKSSession.make(mode: .direct, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        var status = 0
        let verdict: MTSLinkMeetingVerdict
        do {
            let (data, response) = try await session.data(for: req)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            verdict = Self.verdict(status: status, body: data)
        } catch {
            verdict = .unknown
        }
        await log("MTS Link meeting check: event \(id) — \(verdict.logText) (HTTP \(status))")
        return verdict
    }

    /// The look at a meeting made a moment ago: asked again while its session
    /// may still be on the way.
    static func checkFresh(link: String) async -> MTSLinkMeetingVerdict {
        var verdict = await check(link: link)
        var attempt = 1
        while attempt < freshAttempts, worthAskingAgain(verdict), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(freshPause * 1_000_000_000))
            verdict = await check(link: link)
            attempt += 1
        }
        return verdict
    }

    /// The line that refuses the first MTS Link room among `options` the
    /// server could not enter; nil when every one is usable (or there is none).
    static func refusal(for options: [InstallOptions]) async -> String? {
        for room in roomsToCheck(options) {
            if let line = await check(link: room).refusal { return line }
        }
        return nil
    }

    /// Throws `MTSLinkRoomError.unusableMeeting` when `options` would hand the
    /// server an MTS Link room it cannot enter. The Provisioner runs this
    /// before it touches the server.
    static func require(_ options: InstallOptions) async throws {
        for room in roomsToCheck([options]) {
            let verdict = await check(link: room)
            guard verdict.isUsable else { throw MTSLinkRoomError.unusableMeeting(verdict) }
        }
    }

    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}
