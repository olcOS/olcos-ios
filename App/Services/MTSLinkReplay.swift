import Foundation
import UIKit
import WebKit

// MARK: - MTSLinkReplayRules (pure)
//
// The decisions of a silent replay, as pure functions: which values the learned
// headers need, how they are put together from the page's sources, what the
// answer means. The web view half is MTSLinkReplay below.
enum MTSLinkReplayRules {

    /// What the signed-in page holds, for the sources the template names.
    struct Sources: Equatable {
        var cookies: [String: String] = [:]
        var local: [String: String] = [:]
        var session: [String: String] = [:]
        /// The latest value of each credential-named header the page itself
        /// sent, keyed by the lower-case header name (MTSLinkHook).
        var seen: [String: String] = [:]
    }

    /// PURE. The names to ask the page for, by kind — only names, never
    /// everything the page stores.
    static func wanted(for headers: [MTSLinkHeader]) -> [String: [String]] {
        var cookies: [String] = [], local: [String] = [], session: [String] = [], seen: [String] = []
        for header in headers {
            switch header.kind {
            case .literal: break
            case .cookie:  cookies.append(header.value)
            case .local:   local.append(header.value)
            case .session: session.append(header.value)
            case .seen:    seen.append(header.value.lowercased())
            }
        }
        return ["cookies": cookies, "local": local, "session": session, "seen": seen]
    }

    /// PURE. The headers to send, rebuilt from the template's provenance. A
    /// credential header whose source cannot be resolved aborts with
    /// `.missingToken(name)`: a request the original sent with a token is never
    /// sent without one.
    static func assemble(_ headers: [MTSLinkHeader],
                         from sources: Sources) -> Result<[String: String], MTSLinkRoomError> {
        var out: [String: String] = [:]
        for header in headers {
            let value: String?
            switch header.kind {
            case .literal:
                out[header.name] = header.value
                continue
            case .cookie:  value = sources.cookies[header.value]
            case .local:   value = sources.local[header.value]
            case .session: value = sources.session[header.value]
            case .seen:    value = sources.seen[header.value.lowercased()]
            }
            guard var found = value, !found.isEmpty else { return .failure(.missingToken(header.name)) }
            // A `seen` value is the whole header as the page sent it, `Bearer ` included.
            if header.bearer && header.kind != .seen { found = "Bearer " + found }
            out[header.name] = found
        }
        return .success(out)
    }

    // MARK: Markers in the URL and the body

    private static let embedded = try! NSRegularExpression(pattern: #"<<olc:(cookie|local|session):(.+?)(;enc)?>>"#)

    /// The request with every marker resolved, ready for the page.
    struct Resolved: Equatable {
        var url: String
        var headers: [String: String]
        var payload: MTSLinkPayload
    }

    struct Marker: Equatable {
        var kind: String   // cookie | local | session
        var name: String
        var encoded: Bool
    }

    /// PURE. The `<<olc:…>>` markers inside a string, in order.
    static func markers(in text: String) -> [Marker] {
        guard text.contains("<<olc:") else { return [] }
        let ns = text as NSString
        return embedded.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            Marker(kind: ns.substring(with: match.range(at: 1)),
                   name: ns.substring(with: match.range(at: 2)),
                   encoded: match.range(at: 3).location != NSNotFound)
        }
    }

    /// PURE. The marker a whole field value stands for (`olc:cookie:NAME`), or
    /// nil for an ordinary value.
    static func fieldMarker(_ value: String) -> Marker? {
        guard let marker = MTSLinkProvenance.parse(value), marker.kind != .seen,
              marker.kind != .literal else { return nil }
        return Marker(kind: marker.kind.rawValue, name: marker.name, encoded: false)
    }

    /// PURE. The cookie / storage names the template needs, headers included.
    static func wanted(for template: MTSLinkTemplate) -> [String: [String]] {
        var out = wanted(for: template.headers)
        func note(_ marker: Marker) {
            let key = marker.kind == "cookie" ? "cookies" : marker.kind
            if !(out[key] ?? []).contains(marker.name) { out[key, default: []].append(marker.name) }
        }
        markers(in: template.url).forEach(note)
        markers(in: template.payload.text).forEach(note)
        for field in template.payload.fields {
            if let marker = fieldMarker(field.value) { note(marker) }
        }
        return out
    }

    /// PURE. How many markers the URL and the body hold (for the log).
    static func markerCount(_ template: MTSLinkTemplate) -> Int {
        markers(in: template.url).count + markers(in: template.payload.text).count
            + template.payload.fields.filter { fieldMarker($0.value) != nil }.count
    }

    private static func lookup(_ marker: Marker, _ sources: Sources) -> String? {
        let value: String?
        switch marker.kind {
        case "cookie": value = sources.cookies[marker.name]
        case "local":  value = sources.local[marker.name]
        default:       value = sources.session[marker.name]
        }
        guard let found = value, !found.isEmpty else { return nil }
        return found
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// PURE. `encodeURIComponent`.
    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// PURE. The inside of a JSON string literal.
    static func jsonEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// PURE. `text` with its `<<olc:…>>` markers replaced by the page's values:
    /// URL-encoded where the marker says so, JSON-escaped inside a JSON body,
    /// as they are anywhere else. A marker the page gives no value for aborts
    /// with `.missingToken(NAME)`.
    static func resolveText(_ text: String, from sources: Sources,
                            json: Bool) -> Result<String, MTSLinkRoomError> {
        guard text.contains("<<olc:") else { return .success(text) }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in embedded.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let marker = Marker(kind: ns.substring(with: match.range(at: 1)),
                                name: ns.substring(with: match.range(at: 2)),
                                encoded: match.range(at: 3).location != NSNotFound)
            guard let value = lookup(marker, sources) else { return .failure(.missingToken(marker.name)) }
            out += marker.encoded ? percentEncode(value) : (json ? jsonEscape(value) : value)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return .success(out)
    }

    /// PURE. The whole request for the page: headers from their provenance, the
    /// URL and the body with their markers resolved. A form body drops the
    /// page's Content-Type header: the browser sets it, and a multipart
    /// boundary, itself.
    static func resolve(_ template: MTSLinkTemplate,
                        from sources: Sources) -> Result<Resolved, MTSLinkRoomError> {
        let headers: [String: String]
        switch assemble(template.headers, from: sources) {
        case .success(let value): headers = value
        case .failure(let error): return .failure(error)
        }
        let url: String
        switch resolveText(template.url, from: sources, json: false) {
        case .success(let value): url = value
        case .failure(let error): return .failure(error)
        }
        var payload = template.payload
        switch payload.kind {
        case .none:
            break
        case .text, .json:
            switch resolveText(payload.text, from: sources, json: payload.kind == .json) {
            case .success(let value): payload.text = value
            case .failure(let error): return .failure(error)
            }
        case .urlencoded, .formData:
            var fields: [MTSLinkPayload.Field] = []
            for field in payload.fields {
                if let marker = fieldMarker(field.value) {
                    guard let value = lookup(marker, sources) else { return .failure(.missingToken(marker.name)) }
                    fields.append(MTSLinkPayload.Field(name: field.name, value: value))
                } else {
                    fields.append(field)
                }
            }
            payload.fields = fields
        }
        var sent = headers
        if payload.isForm {
            sent = sent.filter { $0.key.lowercased() != "content-type" }
        }
        return .success(Resolved(url: url, headers: sent, payload: payload))
    }

    /// PURE. The arguments of the in-page script: the body kind and its parts
    /// (the script rebuilds a `URLSearchParams`, a `FormData` or the string).
    static func fetchArguments(_ request: Resolved, method: String, timeoutMs: Int) -> [String: Any] {
        [
            "method": method,
            "url": request.url,
            "headers": request.headers,
            "bodyKind": request.payload.kind.rawValue,
            "bodyText": request.payload.text,
            "fields": request.payload.fields.map { [$0.name, $0.value] },
            "timeoutMs": timeoutMs,
        ]
    }

    /// PURE. Whether the page the web view ended on is a sign-in or registration
    /// page: the saved session is dead.
    static func isSignedOutURL(_ url: String) -> Bool {
        let lower = MTSLinkURL.withoutQuery(url).lowercased()
        for marker in ["/login", "/signin", "/sign-in", "/signup", "/sign-up", "/auth", "/sso",
                       "/registration", "/register"] {
            if lower.contains(marker) { return true }
        }
        if let host = URL(string: lower)?.host {
            for prefix in ["login.", "id.", "sso.", "auth."] where host.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// The start of an answer for the one-line reason: scrubbed, on one line.
    @MainActor
    static func answerHead(_ text: String) -> String {
        let cleaned = MTSLinkScrub.text(String(text.prefix(300)), limit: 600)
        let oneLine = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(oneLine.prefix(160))
    }

    /// PURE. What the answer to the replayed request means. 401/403 is a
    /// sign-in problem (with its status and answer head, so a plan-cap refusal
    /// reads differently from a lost sign-in), 429/503 a refusal for now, any other non-2xx a service
    /// error; a 2xx must carry a meeting the template can read, and not the one
    /// that is already current.
    @MainActor
    static func interpret(status: Int, text: String, template: MTSLinkTemplate,
                          current: String) -> Result<String, MTSLinkRoomError> {
        switch status {
        case 401, 403:  return .failure(.rejected(status: status, head: answerHead(text)))
        case 429, 503:  return .failure(.rateLimited)
        case 200..<300: break
        default:        return .failure(.serviceError(status: status))
        }
        guard let room = template.room(fromResponse: text) else { return .failure(.malformedResponse) }
        if !current.isEmpty, RoomIdentity.same(room, current, carrier: "mtslink") {
            return .failure(.sameRoom)
        }
        return .success(room)
    }
}

// MARK: - MTSLinkReplay
//
// "Make a room", silent. An OFFSCREEN web view on the DEFAULT data store (the
// one the sign-in sheet signed in on) loads the cabinet page; the same hook as
// the sheet's (MTSLinkHook) keeps, in page memory, the latest value of every
// credential-named header the page sends. When the page is up and the values
// the template needs are there, the learned request runs INSIDE the page —
// `fetch` with `credentials: "include"` — so the page's own cookies and tokens
// travel and nothing of them is ever stored or logged. Only `{status, text}`
// comes back. The whole run is bounded at `totalSeconds`.
@MainActor
final class MTSLinkReplay: NSObject, WKNavigationDelegate {

    static let totalSeconds: TimeInterval = 25
    static let loadSeconds: TimeInterval = 12
    static let tokenWaitSeconds: TimeInterval = 6
    /// Time for a client-side redirect to a sign-in page after the load.
    static let settleSeconds: TimeInterval = 1.5

    private var webView: WKWebView?
    private var loadWaiter: CheckedContinuation<Bool, Never>?

    static func run(template: MTSLinkTemplate, current: String) async -> Result<String, MTSLinkRoomError> {
        let replay = MTSLinkReplay()
        let result = await replay.execute(template, current: current)
        replay.teardown()
        return result
    }

    // MARK: The run

    private func execute(_ template: MTSLinkTemplate, current: String) async -> Result<String, MTSLinkRoomError> {
        let deadline = Date().addingTimeInterval(Self.totalSeconds)
        Self.log("start — \(template.method) \(MTSLinkURL.withoutQuery(template.url))")
        guard MTSLinkURL.isMTSLink(template.url) else {
            Self.log("refused — the template does not point at mts-link.ru over HTTPS")
            return .failure(.noCreateRequest)
        }

        let web = makeWebView()
        webView = web
        guard await load(web, within: min(Self.loadSeconds, Self.remaining(deadline))) else {
            Self.log("the cabinet page did not load")
            return .failure(.networkUnavailable)
        }
        Self.log("page loaded — \(MTSLinkURL.withoutQuery(web.url?.absoluteString ?? ""))")

        // The values the learned headers need, from the page's own sources.
        let wanted = MTSLinkReplayRules.wanted(for: template)
        let tokenDeadline = min(deadline, Date().addingTimeInterval(Self.tokenWaitSeconds))
        var assembled: Result<MTSLinkReplayRules.Resolved, MTSLinkRoomError> = .failure(.missingToken(""))
        while true {
            let sources = await readSources(web, wanted: wanted)
            assembled = MTSLinkReplayRules.resolve(template, from: sources)
            if case .success = assembled { break }
            if Date() >= tokenDeadline { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // A page that redirected to a sign-in form means the saved sign-in is dead.
        if Date() < deadline { try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000)) }
        let href = web.url?.absoluteString ?? ""
        if MTSLinkReplayRules.isSignedOutURL(href) {
            Self.log("the page ended on a sign-in page (\(MTSLinkURL.withoutQuery(href))) — signed out")
            return .failure(.sessionRejected)
        }

        let request: MTSLinkReplayRules.Resolved
        switch assembled {
        case .success(let value):
            request = value
            Self.log("token sources resolved — " + Self.sourceNames(template))
        case .failure(let error):
            Self.log("token sources — \(error.logText)")
            return .failure(error)
        }

        guard MTSLinkURL.isMTSLink(request.url) else {
            Self.log("refused — the resolved address is not on mts-link.ru")
            return .failure(.noCreateRequest)
        }
        let timeoutMs = max(3_000, Int(Self.remaining(deadline) * 1000))
        switch await runFetch(web, template: template, request: request, timeoutMs: timeoutMs) {
        case .failed(let message):
            Self.log("the request failed — \(MTSLinkScrub.text(message, limit: 200))")
            return .failure(message.lowercased().contains("abort") ? .timedOut : .networkUnavailable)
        case .answer(let status, let text):
            Self.log("HTTP \(status): " + MTSLinkScrub.text(String(text.prefix(300)), limit: 600))
            let verdict = MTSLinkReplayRules.interpret(status: status, text: text, template: template,
                                                       current: current)
            switch verdict {
            case .success(let room):
                if let event = MTSLinkRoomService.eventId(of: room) {
                    MTSLinkCreatedRooms.remember(event)
                    Self.log("event id found — \(event)")
                }
            case .failure(let error):
                if error == .malformedResponse { Self.log("event id not found in the answer") }
                if error == .sameRoom { Self.log("the answer is the room that is already current") }
            }
            return verdict
        }
    }

    private static func sourceNames(_ template: MTSLinkTemplate) -> String {
        var names = template.headers.filter { $0.kind != .literal }.map(\.sourceSummary)
        let markers = MTSLinkReplayRules.markerCount(template)
        if markers > 0 { names.append("\(markers) cookie/storage values in the address and body") }
        return names.isEmpty ? "none needed" : names.joined(separator: ", ")
    }

    private static func remaining(_ deadline: Date) -> TimeInterval {
        max(1, deadline.timeIntervalSinceNow)
    }

    // MARK: The web view

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // The DEFAULT store: the sign-in the sheet made lives here.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // The same desktop disguise as the sign-in sheet, so the site sees one browser.
        config.userContentController.addUserScript(WKUserScript(
            source: MTSLinkDesktop.shimScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(
            source: MTSLinkHook.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: -3000, y: 0, width: 1024, height: 768), configuration: config)
        web.customUserAgent = MTSLinkRoomService.desktopUserAgent
        web.navigationDelegate = self
        // Out of sight but in a window: a page that is not in one may not run
        // its timers and animation frames.
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(web)
        return web
    }

    private func teardown() {
        finishLoad(false)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func load(_ web: WKWebView, within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loadWaiter = continuation
            web.load(URLRequest(url: MTSLinkRoomService.webOrigin))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.finishLoad(false)
            }
        }
    }

    private func finishLoad(_ ok: Bool) {
        guard let waiter = loadWaiter else { return }
        loadWaiter = nil
        waiter.resume(returning: ok)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finishLoad(false)
    }

    // MARK: In the page

    private enum FetchResult {
        case answer(Int, String)
        case failed(String)
    }

    /// Runs `body` as an async function in the page and returns what it resolves to.
    /// Calls WebKit's Objective-C method directly: the Swift forms of
    /// `callAsyncJavaScript` live in `libswiftWebKit.dylib`, which an app built for
    /// iOS 17 links and the iOS 18 runtime no longer ships, so using them kept the
    /// app from launching ("Library not loaded: /usr/lib/swift/libswiftWebKit.dylib").
    private func callInPage(_ web: WKWebView, _ body: String, arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.__callAsyncJavaScript(body, arguments: arguments, inFrame: nil, in: .page) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func readSources(_ web: WKWebView, wanted: [String: [String]]) async -> MTSLinkReplayRules.Sources {
        guard let value = try? await callInPage(web, Self.sourcesScript, arguments: ["wanted": wanted]),
              let dict = value as? [String: Any] else { return MTSLinkReplayRules.Sources() }
        func strings(_ key: String) -> [String: String] {
            (dict[key] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        }
        return MTSLinkReplayRules.Sources(cookies: strings("cookies"), local: strings("local"),
                                          session: strings("session"), seen: strings("seen"))
    }

    private func runFetch(_ web: WKWebView, template: MTSLinkTemplate,
                          request: MTSLinkReplayRules.Resolved, timeoutMs: Int) async -> FetchResult {
        let arguments = MTSLinkReplayRules.fetchArguments(request, method: template.method,
                                                          timeoutMs: timeoutMs)
        do {
            let value = try await callInPage(web, Self.fetchScript, arguments: arguments)
            guard let dict = value as? [String: Any] else { return .failed("no answer") }
            if let status = dict["status"] as? Int {
                return .answer(status, dict["text"] as? String ?? "")
            }
            return .failed(dict["error"] as? String ?? "no answer")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Reads only the values the template names. The result stays in memory.
    static let sourcesScript = #"""
    const out = { cookies: {}, local: {}, session: {}, seen: {} };
    const jar = {};
    try {
        document.cookie.split(";").forEach(function(p) {
            const i = p.indexOf("=");
            if (i > 0) { jar[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }
        });
    } catch (e) {}
    const seen = window.__olcosSeen || {};
    (wanted.cookies || []).forEach(function(n) { if (jar[n] !== undefined) { out.cookies[n] = jar[n]; } });
    (wanted.local || []).forEach(function(k) {
        try { const v = window.localStorage.getItem(k); if (v !== null) { out.local[k] = v; } } catch (e) {}
    });
    (wanted.session || []).forEach(function(k) {
        try { const v = window.sessionStorage.getItem(k); if (v !== null) { out.session[k] = v; } } catch (e) {}
    });
    (wanted.seen || []).forEach(function(n) { if (seen[n] !== undefined) { out.seen[n] = seen[n]; } });
    return out;
    """#

    /// The learned request, as the page itself would send it.
    static let fetchScript = #"""
    const init = { method: method, headers: headers, credentials: "include" };
    if (method !== "GET" && method !== "HEAD") {
        // The same kind of body the page sent; for a form the browser sets the
        // content type and the multipart boundary itself.
        if (bodyKind === "urlencoded") {
            const params = new URLSearchParams();
            fields.forEach(function(f) { params.append(f[0], f[1]); });
            init.body = params;
        } else if (bodyKind === "formData") {
            const form = new FormData();
            fields.forEach(function(f) { form.append(f[0], f[1]); });
            init.body = form;
        } else if (bodyKind === "text" || bodyKind === "json") {
            init.body = bodyText;
        }
    }
    const controller = new AbortController();
    const timer = setTimeout(function() { controller.abort(); }, timeoutMs);
    init.signal = controller.signal;
    try {
        const response = await fetch(url, init);
        const text = await response.text();
        return { status: response.status, text: text.slice(0, 16384) };
    } catch (e) {
        return { error: String(e) };
    } finally {
        clearTimeout(timer);
    }
    """#

    private static func log(_ line: String) {
        LogStore.shared.log(.provisioning, "MTS Link replay: " + line)
    }
}
