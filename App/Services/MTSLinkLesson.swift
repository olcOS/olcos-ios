import Foundation

// MARK: - What the sign-in sheet recorded in one lesson
//
// The owner makes a permanent meeting by hand inside the sheet and presses
// Finish. Only then does the app look at what THIS session of the sheet
// recorded — the calls the page made and the meeting pages it showed — and work
// out which call made the meeting. Nothing here guesses at an endpoint: a
// template can only come from a call the owner's own page made.

/// One fetch / XHR the page made, with the answer.
struct MTSLinkLessonCall: Equatable {
    var id: Int
    /// Seconds on the capture's clock (monotonic), not a date.
    var at: TimeInterval
    /// Scrubbed (MTSLinkProvenance markers, no credential values).
    var request: CapturedRequest
    /// The size of the body as sent — `request.body` is capped.
    var bodyBytes: Int
    var status: Int
    /// The answer as received (first 16 KB). In memory only: read for the id,
    /// never printed, never stored.
    var response: String
    /// The request as the page sent it (URL, headers, body kind and fields),
    /// with cookie/storage-equal parts as markers — the source of the template.
    /// In memory only, never printed; `request` is the scrubbed copy shown.
    var raw: MTSLinkRawRequest? = nil
}

/// A meeting the page navigated to or showed.
struct MTSLinkSighting: Equatable {
    enum Source: Equatable { case navigation, page }
    var at: TimeInterval
    var source: Source
    var event: String
    var owner: String
    /// `https://my.mts-link.ru/j/<owner>/<event>`
    var link: String
}

/// A meeting the lesson found.
struct MTSLinkMeeting: Equatable, Identifiable {
    var event: String
    var owner: String
    var link: String
    /// The id of the create call that produced it; nil when the page merely
    /// showed it (a navigation, the page text).
    var createCall: Int?

    var id: String { event }
    var madeByCall: Bool { createCall != nil }
}

enum MTSLinkLessonOutcome: Equatable {
    case none
    case one(MTSLinkMeeting)
    case several([MTSLinkMeeting])
}

// MARK: - MTSLinkLesson (pure)

enum MTSLinkLesson {

    /// How long after a create call its meeting may show up on the page when
    /// the call carried only a number (the meeting's link is built from it).
    static let numericWindow: TimeInterval = 10
    /// …and when the call carried the join link itself.
    static let linkWindow: TimeInterval = 60
    /// Page work and the report of an answer are not in step; a meeting shown
    /// up to this long before the answer was read still came from that call.
    static let slack: TimeInterval = 2
    /// A response carrying more distinct numbers than this lists things rather
    /// than creates one.
    static let maxListedIDs = 8
    /// The shortest number taken for a meeting's id.
    static let minEventDigits = 6

    private static let numericRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])[0-9]{6,20}(?![0-9A-Za-z])"#)

    static func isMutating(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH"].contains(method.uppercased())
    }

    /// PURE. Every meeting link in `text` (a page URL, the page's text), as
    /// sightings. The event is the SECOND number after `/j/`; whatever follows
    /// it — `/stream-new/<session>`, `/session/<id>`, a query — is dropped.
    static func sightings(in text: String, at: TimeInterval,
                          source: MTSLinkSighting.Source) -> [MTSLinkSighting] {
        MTSLinkRoom.links(in: text).compactMap { link in
            guard let plain = MTSLinkRoom.plain(link),
                  let event = MTSLinkRoom.event(of: plain),
                  let owner = MTSLinkRoom.owner(of: plain) else { return nil }
            return MTSLinkSighting(at: at, source: source, event: event, owner: owner, link: plain)
        }
    }

    /// PURE. The distinct numbers of six digits or more in `text`, in order.
    static func numericIDs(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for match in numericRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range)
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    struct Candidate: Equatable {
        var call: MTSLinkLessonCall
        var event: String
        var owner: String
        var viaLink: Bool
    }

    /// PURE. The calls that may have made a meeting, one entry per meeting each
    /// of them could have made: a POST / PUT / PATCH answered 2xx whose answer
    /// carries (a) a join link the request did not carry, or (b) a number of
    /// six digits or more the request did not carry — and that meeting then
    /// shows up on the page, for the first time, shortly after the answer. A
    /// GET never qualifies (a list mentions old meetings), nor does a meeting
    /// the page already showed before the call, nor an answer that lists
    /// several things.
    static func candidates(calls: [MTSLinkLessonCall], sightings: [MTSLinkSighting]) -> [Candidate] {
        var out: [Candidate] = []
        for call in calls.sorted(by: { $0.at < $1.at }) {
            guard isMutating(call.request.method), (200..<300).contains(call.status) else { continue }
            let carried = call.request.url + " " + call.request.body
            let carriedEvents = Set(MTSLinkRoom.links(in: carried).compactMap { MTSLinkRoom.event(of: $0) })
            var linkEvents: [String] = []
            for link in MTSLinkRoom.links(in: call.response) {
                if let event = MTSLinkRoom.event(of: link), !carriedEvents.contains(event),
                   !linkEvents.contains(event) { linkEvents.append(event) }
            }
            let viaLink = !linkEvents.isEmpty
            let events = viaLink ? linkEvents
                                 : numericIDs(in: call.response).filter { !carried.contains($0) }
            if events.count > (viaLink ? 1 : maxListedIDs) { continue }
            let window = viaLink ? linkWindow : numericWindow
            for event in events {
                // A meeting the page showed before this call is not its work.
                guard let first = sightings.first(where: { $0.event == event }),
                      first.at >= call.at - slack else { continue }
                guard let seen = sightings.first(where: {
                    $0.event == event && $0.at >= call.at - slack && $0.at - call.at <= window
                }) else { continue }
                out.append(Candidate(call: call, event: event, owner: seen.owner, viaLink: viaLink))
            }
        }
        return out
    }

    /// PURE. What the lesson found, for the confirmation the owner sees after
    /// pressing Finish.
    ///
    /// * a create call matched a meeting → that meeting (and the page's last
    ///   navigation, if it ended on another meeting: then both are listed);
    /// * no such call → the meetings the page navigated to; with no navigation
    ///   at all, the meetings it showed after the first change was saved;
    /// * none → `.none`; more than one → `.several` (nothing is learned from a
    ///   lesson that is not unambiguous).
    static func analyze(calls: [MTSLinkLessonCall], sightings: [MTSLinkSighting],
                        dismissed: Set<String> = []) -> MTSLinkLessonOutcome {
        let strong = candidates(calls: calls, sightings: sightings).filter { !dismissed.contains($0.event) }
        let visible = sightings.filter { !dismissed.contains($0.event) }
        let endedOn = visible.last(where: { $0.source == .navigation })?.event

        var events = distinct(strong.map(\.event))
        if events.isEmpty {
            let navigated = distinct(visible.filter { $0.source == .navigation }.map(\.event))
            if !navigated.isEmpty {
                events = navigated
            } else if let firstChange = calls
                .filter({ isMutating($0.request.method) && (200..<300).contains($0.status) })
                .map(\.at).min() {
                events = distinct(visible.filter { $0.source == .page && $0.at >= firstChange - slack }
                    .map(\.event))
            }
        } else if let ended = endedOn, !events.contains(ended) {
            events.append(ended)
        }

        func meeting(_ event: String) -> MTSLinkMeeting {
            let create = strong.first { $0.event == event }
            let owner = create?.owner ?? visible.last(where: { $0.event == event })?.owner ?? "0"
            return MTSLinkMeeting(event: event, owner: owner,
                                  link: "https://my.mts-link.ru/j/\(owner)/\(event)",
                                  createCall: create?.call.id)
        }
        switch events.count {
        case 0:  return .none
        case 1:  return .one(meeting(events[0]))
        default: return .several(events.map(meeting))
        }
    }

    /// PURE. The template for a meeting a create call made; nil for a meeting
    /// the page only showed.
    static func template(for meeting: MTSLinkMeeting, calls: [MTSLinkLessonCall],
                         now: Date = Date()) -> Result<MTSLinkTemplate, MTSLinkTemplate.BuildFailure>? {
        guard let id = meeting.createCall, let call = calls.first(where: { $0.id == id }) else { return nil }
        return MTSLinkTemplate.build(from: call, event: meeting.event, owner: meeting.owner, now: now)
    }

    private static func distinct(_ values: [String]) -> [String] {
        var out: [String] = []
        for value in values where !out.contains(value) { out.append(value) }
        return out
    }
}

// MARK: - MTSLinkRequestCapture
//
// What the sign-in sheet watched the page do: a bounded, scrubbed list behind a
// "what the app saw" disclosure with a copy-to-clipboard dump the owner can
// paste to the developer, and the raw material of the lesson. The buffer lives
// in the sheet's lifetime and goes nowhere else. It adopts NOTHING by itself:
// the sheet asks for the analysis when the owner presses Finish.
@MainActor
final class MTSLinkRequestCapture: ObservableObject {

    /// One captured request and what came back.
    struct Seen: Identifiable, Equatable {
        let id: Int
        let request: CapturedRequest
        let status: Int
        /// The first part of the answer, scrubbed.
        let responseHead: String
        /// A meeting link this response introduced, if any.
        let newLink: String?
    }

    /// The buffer: newest last, at most `maxRequests` entries.
    @Published private(set) var entries: [Seen] = []
    /// A call that looks like it made a meeting has been seen — only ever shown
    /// as a hint to press Finish.
    @Published private(set) var meetingHint = false

    private(set) var calls: [MTSLinkLessonCall] = []
    private(set) var sightings: [MTSLinkSighting] = []
    private var dismissed: Set<String> = []
    private var lines: [String] = []
    private var nextID = 0
    private var lastNavigation = ""
    private let clock: () -> TimeInterval
    private let origin: TimeInterval

    static let maxRequests = 100
    static let maxLines = 300
    static let responseHeadChars = 600

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.origin = clock()
    }

    /// The capture of one request/response pair. Static traffic never lands
    /// here (`isInteresting`).
    /// `page` is the page's own copy of the request (MTSLinkRawRequest.parse), for
    /// the template; the list, the log and the dump show only the scrubbed one.
    func record(method: String, url: String, headers: [String: String],
                body: String, status: Int, response: String, page: MTSLinkRawRequest? = nil) {
        guard Self.isInteresting(url) else { return }
        let request = CapturedRequest.scrubbed(method: method, url: url, headers: headers, body: body)
        let call = MTSLinkLessonCall(id: nextID, at: clock(), request: request,
                                     bodyBytes: page?.payload.byteCount ?? body.utf8.count,
                                     status: status, response: response, raw: page)
        nextID += 1
        calls.append(call)
        if calls.count > Self.maxRequests { calls.removeFirst(calls.count - Self.maxRequests) }

        // A link the ANSWER brought back and the request did not carry.
        let introduced = MTSLinkRoom.links(in: response)
            .first { !request.body.contains($0) && !request.url.contains($0) }
        let seen = Seen(id: call.id, request: request, status: status,
                        responseHead: MTSLinkScrub.text(String(response.prefix(Self.responseHeadChars)),
                                                        limit: 2048),
                        newLink: introduced)
        entries.append(seen)
        if entries.count > Self.maxRequests { entries.removeFirst(entries.count - Self.maxRequests) }
        addLine(format(seen))
        refreshHint()
    }

    /// The page moved to `url`.
    func recordNavigation(url: String) {
        let shown = MTSLinkURL.withoutQuery(url)
        guard shown != lastNavigation else { return }
        lastNavigation = shown
        let found = MTSLinkLesson.sightings(in: url, at: clock(), source: .navigation)
        sightings.append(contentsOf: found)
        addLine("navigation \(shown)" + (found.isEmpty ? "" : " — meeting \(found.map(\.event).joined(separator: ","))"))
        refreshHint()
    }

    /// The meeting links the page shows right now.
    func recordPage(links: [String]) {
        let found = MTSLinkLesson.sightings(in: links.joined(separator: "\n"), at: clock(), source: .page)
        let fresh = found.filter { new in
            !sightings.contains { $0.source == .page && $0.event == new.event }
        }
        guard !fresh.isEmpty else { return }
        sightings.append(contentsOf: fresh)
        addLine("page shows meeting " + fresh.map(\.event).joined(separator: ","))
        refreshHint()
    }

    /// What the lesson found so far (the owner pressed Finish).
    func analysis() -> MTSLinkLessonOutcome {
        MTSLinkLesson.analyze(calls: calls, sightings: sightings, dismissed: dismissed)
    }

    /// The owner said "not this one".
    func dismiss(event: String) {
        dismissed.insert(event)
        addLine("owner rejected meeting \(event)")
        refreshHint()
    }

    func template(for meeting: MTSLinkMeeting) -> Result<MTSLinkTemplate, MTSLinkTemplate.BuildFailure>? {
        MTSLinkLesson.template(for: meeting, calls: calls)
    }

    /// Lines the sheet adds to the dump (outcome, template shape) — scrubbed
    /// text only.
    func note(_ line: String) {
        addLine(line)
    }

    /// The copy-to-clipboard dump: every captured call and page event, already
    /// scrubbed, in order.
    func dump() -> String {
        (["MTS Link lesson log — \(calls.count) calls, \(sightings.count) page sightings"] + lines)
            .joined(separator: "\n")
    }

    private func refreshHint() {
        let hint = !MTSLinkLesson.candidates(calls: calls, sightings: sightings)
            .filter { !dismissed.contains($0.event) }.isEmpty
        if hint != meetingHint { meetingHint = hint }
    }

    private func addLine(_ text: String) {
        let offset = String(format: "%.1f", clock() - origin)
        lines.append("[+\(offset)s] \(text)")
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    private func format(_ seen: Seen) -> String {
        var out = ["#\(seen.id) \(seen.request.summary) → \(seen.status)"]
        for (name, value) in seen.request.headers.sorted(by: { $0.key < $1.key }) {
            out.append("  \(name): \(value)")
        }
        if !seen.request.body.isEmpty { out.append("  body: \(seen.request.body)") }
        if !seen.responseHead.isEmpty { out.append("  response: \(seen.responseHead)") }
        if let link = seen.newLink { out.append("  new meeting link: \(link)") }
        return out.joined(separator: "\n")
    }

    /// PURE. Static assets carry no API shape worth a slot in the buffer.
    static func isInteresting(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard !lower.isEmpty else { return false }
        for suffix in [".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg",
                       ".webp", ".ico", ".woff", ".woff2", ".ttf", ".map"] {
            if lower.hasSuffix(suffix) || lower.contains(suffix + "?") { return false }
        }
        return true
    }
}
