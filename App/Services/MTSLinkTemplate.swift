import Foundation

// MARK: - MTSLinkProvenance
//
// Where the value of a credential header comes from. The page-side hook
// (MTSLinkHook) works it out IN the page and sends only a marker, so a
// credential value never reaches the app:
//
//   olc:cookie:NAME   the value equals the cookie NAME at the moment of the call
//   olc:local:KEY     … localStorage[KEY]
//   olc:session:KEY   … sessionStorage[KEY]
//   olc:seen:NAME     none of those: take the latest value the page itself
//                     sends under the header NAME when the template runs
//
// `+bearer` after the kind (`olc:cookie+bearer:NAME`) means the header value is
// `Bearer <value>`.
enum MTSLinkProvenance {

    enum Kind: String, Codable, Sendable {
        case literal, cookie, local, session, seen
    }

    struct Marker: Equatable {
        var kind: Kind
        var name: String
        var bearer: Bool
    }

    static func marker(kind: Kind, name: String, bearer: Bool = false) -> String {
        "olc:\(kind.rawValue)\(bearer ? "+bearer" : ""):\(name)"
    }

    /// PURE. The marker a header value stands for, or nil for an ordinary value.
    static func parse(_ value: String) -> Marker? {
        guard value.hasPrefix("olc:") else { return nil }
        let rest = value.dropFirst(4)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let kindPart = String(rest[..<colon])
        let name = String(rest[rest.index(after: colon)...])
        guard !name.isEmpty else { return nil }
        let pieces = kindPart.components(separatedBy: "+")
        guard pieces.count <= 2, let kind = Kind(rawValue: pieces[0]), kind != .literal else { return nil }
        if pieces.count == 2 && pieces[1] != "bearer" { return nil }
        return Marker(kind: kind, name: name, bearer: pieces.count == 2)
    }

    /// PURE. Names the page-side hook (and so the template builder) treats as
    /// credential-bearing: their VALUE is never stored.
    static func isCredentialName(_ name: String) -> Bool {
        let lower = name.lowercased()
        for part in ["auth", "token", "csrf", "xsrf", "api-key", "api_key", "apikey", "secret", "session"] {
            if lower.contains(part) { return true }
        }
        return false
    }

    /// PURE. A value that is itself a credential whatever its header is called
    /// (a JWT, with or without `Bearer `).
    static func looksLikeSecret(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("eyj") || lower.hasPrefix("bearer eyj")
    }

    /// Headers a page cannot set or that a replay must not carry over.
    static let skippedHeaders: Set<String> = ["cookie", "set-cookie", "host", "content-length", "connection",
                                              "accept-encoding", "user-agent", "origin", "referer"]
}

// MARK: - MTSLinkHeader

/// One header the page set, and where its value comes from at replay time.
struct MTSLinkHeader: Codable, Equatable, Sendable {
    var name: String
    var kind: MTSLinkProvenance.Kind
    /// `.literal`: the value. Otherwise the cookie / storage key / header name.
    var value: String
    var bearer: Bool

    /// PURE. The header as a template keeps it, from what the hook reported:
    /// a marker keeps its provenance, a credential-looking value is never kept
    /// (it can only be taken from the page again), an ordinary value is a
    /// literal. nil for headers a replay must not set.
    static func make(name: String, reported: String) -> MTSLinkHeader? {
        if MTSLinkProvenance.skippedHeaders.contains(name.lowercased()) { return nil }
        if let marker = MTSLinkProvenance.parse(reported) {
            return MTSLinkHeader(name: name, kind: marker.kind, value: marker.name, bearer: marker.bearer)
        }
        if MTSLinkProvenance.isCredentialName(name) || MTSLinkProvenance.looksLikeSecret(reported) {
            return MTSLinkHeader(name: name, kind: .seen, value: name,
                                 bearer: reported.lowercased().hasPrefix("bearer "))
        }
        return MTSLinkHeader(name: name, kind: .literal, value: reported, bearer: false)
    }

    /// PURE. The one-line form for the log: the name and WHERE its value comes
    /// from, never a value.
    var sourceSummary: String {
        switch kind {
        case .literal: return "\(name)=literal"
        default:       return "\(name)=\(kind.rawValue)(\(value))\(bearer ? "+bearer" : "")"
        }
    }
}

// MARK: - MTSLinkJSON

/// Paths into a JSON response: where the new meeting's id sits.
enum MTSLinkJSON {

    struct Step: Codable, Equatable, Sendable {
        var name: String?
        var position: Int?

        static func key(_ k: String) -> Step { Step(name: k, position: nil) }
        static func index(_ i: Int) -> Step { Step(name: nil, position: i) }
    }

    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// PURE. `data.items[0].id`
    static func describe(_ steps: [Step]) -> String {
        var out = ""
        for step in steps {
            if let name = step.name { out += out.isEmpty ? name : ".\(name)" }
            if let position = step.position { out += "[\(position)]" }
        }
        return out
    }

    /// PURE. The value at `steps`, or nil when the path does not exist.
    static func value(at steps: [Step], in json: Any) -> Any? {
        var current: Any = json
        for step in steps {
            if let name = step.name {
                guard let dict = current as? [String: Any], let next = dict[name] else { return nil }
                current = next
            } else if let position = step.position {
                guard let array = current as? [Any], array.indices.contains(position) else { return nil }
                current = array[position]
            } else {
                return nil
            }
        }
        return current
    }

    /// PURE. A string, or an integral number written out as digits.
    static func scalarString(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let text = n.stringValue
            return text.allSatisfy({ $0.isNumber }) ? text : nil
        }
        return nil
    }

    static func string(at steps: [Step], in json: Any) -> String? {
        value(at: steps, in: json).flatMap(scalarString)
    }

    /// PURE. Every place a scalar equal to `id` sits (a string or a number),
    /// the most plausible first: the shallowest, and among equals one whose key
    /// reads like an id.
    static func paths(of id: String, in json: Any) -> [[Step]] {
        collect(in: json) { scalarString($0) == id }
    }

    /// PURE. Every place a string carries a join link of the event `event`.
    static func linkPaths(event: String, in json: Any) -> [[Step]] {
        collect(in: json) { value in
            guard let s = value as? String else { return false }
            return MTSLinkRoom.links(in: s).contains { MTSLinkRoom.event(of: $0) == event }
        }
    }

    private static func collect(in json: Any, where matches: @escaping (Any) -> Bool) -> [[Step]] {
        var found: [[Step]] = []
        func walk(_ node: Any, _ path: [Step]) {
            if let dict = node as? [String: Any] {
                for key in dict.keys.sorted() { walk(dict[key]!, path + [.key(key)]) }
            } else if let array = node as? [Any] {
                for (i, item) in array.enumerated() { walk(item, path + [.index(i)]) }
            } else if matches(node) {
                found.append(path)
            }
        }
        walk(json, [])
        return found.sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            let pa = idLike(a), pb = idLike(b)
            if pa != pb { return pa && !pb }
            return describe(a) < describe(b)
        }
    }

    private static func idLike(_ path: [Step]) -> Bool {
        guard let key = path.last?.name?.lowercased() else { return false }
        return key == "id" || key.hasSuffix("id") || key.hasSuffix("_id")
    }
}

// MARK: - MTSLinkPayload

/// The body of the learned request, as the PAGE sent it — the kind matters,
/// because the replay rebuilds the same kind in the page and lets the browser
/// set the Content-Type (and a multipart boundary) itself.
///
///   text / json   a string; the page's own Content-Type header (if it set one)
///                 travels with the headers
///   urlencoded    a `URLSearchParams`: ordered fields
///   formData      a `FormData`: ordered string fields (a File / Blob part makes
///                 the request impossible to send again, and no template)
///
/// Values equal to a cookie / localStorage / sessionStorage item at capture time
/// are markers computed IN the page: a whole field value is `olc:KIND:NAME`
/// (MTSLinkProvenance); inside a string or a URL it is `<<olc:KIND:NAME>>`
/// (`;enc` before `>>` for a URL-encoded occurrence). They are resolved at
/// replay. Nothing else is rewritten or scrubbed.
struct MTSLinkPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case none, text, json, urlencoded, formData
    }

    struct Field: Codable, Equatable, Sendable {
        var name: String
        var value: String
    }

    var kind: Kind = .none
    var text: String = ""
    var fields: [Field] = []

    var isForm: Bool { kind == .urlencoded || kind == .formData }

    /// The size the payload takes.
    var byteCount: Int {
        text.utf8.count + fields.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
    }
}

// MARK: - MTSLinkRawRequest

/// The request as the page sent it, kept IN MEMORY for the length of a lesson
/// (never printed): the source of the template. The scrubbed copy
/// (`CapturedRequest`) is what the list, the log and the dump show.
struct MTSLinkRawRequest: Equatable {
    /// With `<<olc:…>>` markers for parts equal to a cookie / storage value.
    var url: String
    /// Credential-named headers already replaced by their provenance marker.
    var headers: [String: String]
    var payload: MTSLinkPayload
    /// Why the body cannot be sent again (a file part, a Blob, …); nil if it can.
    var unsupported: String?

    /// The largest body a template keeps.
    static let maxBytes = 256 * 1024

    /// PURE. The page's `tpl` message (see MTSLinkHook): `{url, kind, text,
    /// fields, why}`. nil when it is malformed.
    static func parse(_ message: [String: Any], headers: [String: String]) -> MTSLinkRawRequest? {
        guard let url = message["url"] as? String else { return nil }
        let kind = message["kind"] as? String ?? "none"
        var payload = MTSLinkPayload()
        var unsupported = message["why"] as? String
        switch kind {
        case "none":
            break
        case "text":
            payload = MTSLinkPayload(kind: .text, text: message["text"] as? String ?? "")
        case "json":
            payload = MTSLinkPayload(kind: .json, text: message["text"] as? String ?? "")
        case "urlencoded", "formdata":
            let pairs = (message["fields"] as? [[Any]]) ?? []
            let fields: [MTSLinkPayload.Field] = pairs.compactMap { pair in
                guard pair.count >= 2, let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
                return MTSLinkPayload.Field(name: name, value: value)
            }
            payload = MTSLinkPayload(kind: kind == "urlencoded" ? .urlencoded : .formData, fields: fields)
        default:
            unsupported = unsupported ?? "a body of an unsupported kind"
        }
        if unsupported == nil, payload.byteCount > maxBytes { unsupported = "the body is too large" }
        return MTSLinkRawRequest(url: url, headers: headers, payload: payload, unsupported: unsupported)
    }

    /// The request rebuilt from its scrubbed capture — only for a call that was
    /// recorded without the page's own copy (the body can be partly blank).
    static func fromScrubbed(_ request: CapturedRequest) -> MTSLinkRawRequest {
        let unsupported: String? = request.body.hasPrefix("[object ") ? "a body object" : nil
        let payload = request.body.isEmpty ? MTSLinkPayload() : MTSLinkPayload(kind: .text, text: request.body)
        return MTSLinkRawRequest(url: request.url, headers: request.headers, payload: payload,
                                 unsupported: unsupported)
    }
}

// MARK: - MTSLinkTemplate

/// How the site makes a permanent meeting, as the owner showed it: the request
/// the page sent, as it sent it — a credential header is only a recipe (where
/// its value lives), and a value equal to a cookie or storage item is a marker —
/// and where the new meeting's id sits in the answer. It can hold more than the
/// scrubbed copy shows, so it lives in the KEYCHAIN (MTSLinkTemplateStore), never
/// in UserDefaults, and is never printed.
struct MTSLinkTemplate: Codable, Equatable, Sendable {
    var method: String
    /// As the page sent it, query included; `<<olc:…>>` for cookie/storage parts.
    var url: String
    var contentType: String
    var payload: MTSLinkPayload
    var headers: [MTSLinkHeader]
    var eventPath: [MTSLinkJSON.Step]?
    var linkPath: [MTSLinkJSON.Step]?
    var owner: String
    var learnedAt: Date

    enum BuildFailure: Error, Equatable {
        case notMutating
        case foreignHost
        case bodyUnsupported(String)
        case bodyTooLarge
        case noPathInResponse

        /// Engineering English for the log.
        var reason: String {
            switch self {
            case .notMutating:             return "the request is not a POST, PUT or PATCH"
            case .foreignHost:             return "the request does not go to mts-link.ru over HTTPS"
            case .bodyUnsupported(let why): return "the request body cannot be sent again (\(why))"
            case .bodyTooLarge:            return "the request body is too large to keep"
            case .noPathInResponse:        return "the answer does not carry the meeting's id in a JSON field"
            }
        }
    }

    /// The template from the create call `call` that produced the meeting
    /// `event` (whose page URL named the owner `owner`).
    static func build(from call: MTSLinkLessonCall, event: String, owner: String,
                      now: Date = Date()) -> Result<MTSLinkTemplate, BuildFailure> {
        let request = call.request
        let raw = call.raw ?? MTSLinkRawRequest.fromScrubbed(request)
        guard MTSLinkLesson.isMutating(request.method) else { return .failure(.notMutating) }
        guard MTSLinkURL.isMTSLink(raw.url) else { return .failure(.foreignHost) }
        if let why = raw.unsupported { return .failure(.bodyUnsupported(why)) }
        if max(call.bodyBytes, raw.payload.byteCount) > MTSLinkRawRequest.maxBytes {
            return .failure(.bodyTooLarge)
        }

        var path: (event: [MTSLinkJSON.Step]?, link: [MTSLinkJSON.Step]?) = (nil, nil)
        if let json = MTSLinkJSON.parse(call.response) {
            if let best = MTSLinkJSON.paths(of: event, in: json).first {
                path.event = best
            } else if let best = MTSLinkJSON.linkPaths(event: event, in: json).first {
                path.link = best
            }
        }
        guard path.event != nil || path.link != nil else { return .failure(.noPathInResponse) }

        let headers = raw.headers.keys.sorted().compactMap { name in
            MTSLinkHeader.make(name: name, reported: raw.headers[name] ?? "")
        }
        let contentType = headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
        return .success(MTSLinkTemplate(
            method: request.method.uppercased(),
            url: cleanURL(raw.url),
            contentType: contentType,
            payload: raw.payload,
            headers: headers,
            eventPath: path.event,
            linkPath: path.link,
            owner: MTSLinkRoom.isID(owner) ? owner : "0",
            learnedAt: now))
    }

    /// PURE. The URL without its fragment (which a server never sees); the path
    /// and the query stay exactly as the page sent them.
    static func cleanURL(_ url: String) -> String {
        guard let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }

    /// PURE. The meeting link the answer `response` carries, in the app's one
    /// spelling (no hint), or nil when the recipe finds nothing readable.
    func room(fromResponse response: String) -> String? {
        guard let json = MTSLinkJSON.parse(response) else { return nil }
        if let eventPath, let id = MTSLinkJSON.string(at: eventPath, in: json),
           MTSLinkRoom.isID(id), id.count >= MTSLinkLesson.minEventDigits {
            return "https://my.mts-link.ru/j/\(owner)/\(id)"
        }
        if let linkPath, let text = MTSLinkJSON.string(at: linkPath, in: json),
           let link = MTSLinkRoom.links(in: text).first {
            return MTSLinkRoom.plain(link)
        }
        return nil
    }

    /// PURE. The shape for the log: method, path (no query) and kinds — no values.
    var shapeSummary: String {
        let recipe = eventPath.map { "event at \(MTSLinkJSON.describe($0))" }
            ?? linkPath.map { "link at \(MTSLinkJSON.describe($0))" } ?? "no recipe"
        let names = headers.map(\.sourceSummary).joined(separator: ", ")
        let body = payload.isForm ? "\(payload.kind.rawValue), \(payload.fields.count) fields" : payload.kind.rawValue
        return "\(method) \(MTSLinkURL.withoutQuery(url)) (\(recipe); owner \(owner); body \(body); headers: \(names.isEmpty ? "none" : names))"
    }
}

// MARK: - MTSLinkTemplateStore

/// The template the owner confirmed, kept across launches in the KEYCHAIN (the
/// way the sign-in and the connection secrets are): it holds the request as the
/// page sent it, which can include values a redactor would blank. Both the
/// service and the account are parameters so a test can use its own item.
enum MTSLinkTemplateStore {
    static let service = "olcrtc.mtslink.template"
    static let account = "template"
    /// UserDefaults key of the older template, built from the SCRUBBED capture
    /// (so it may hold blanked values): forgotten, never migrated.
    private static let legacyKey = "olcrtc.mtslink.template.v1"
    /// The key of the older capture-and-replay request, never validated.
    private static let legacyCaptureKey = "olcrtc.mtslink.create-request.v1"
    /// Set once every template stored before the app checked that a meeting is
    /// permanent (MTSLinkMeetingCheck) has been forgotten: such a template may
    /// make quick meetings, which a server cannot enter.
    static let permanentCheckKey = "olcrtc.mtslink.template.permanent-check.v1"

    static var current: MTSLinkTemplate? {
        get {
            dropLegacy()
            return load(service: service, account: account)
        }
        set {
            dropLegacy()
            if let value = newValue {
                save(value, service: service, account: account)
            } else {
                delete(service: service, account: account)
            }
        }
    }

    /// Settings → "Forget what the app learned".
    static func forget() {
        current = nil
    }

    static func load(service: String, account: String) -> MTSLinkTemplate? {
        guard let text = KeychainHelper.get(service: service, account: account),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MTSLinkTemplate.self, from: data)
    }

    @discardableResult
    static func save(_ template: MTSLinkTemplate, service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(template) else { return false }
        return KeychainHelper.set(String(decoding: data, as: UTF8.self), service: service, account: account)
    }

    static func delete(service: String, account: String) {
        KeychainHelper.delete(service: service, account: account)
    }

    /// Forgets the stored template once, the first time this runs; true when
    /// there was one to forget.
    @discardableResult
    static func dropUncheckedOnce(defaults: UserDefaults = .standard,
                                  service: String = MTSLinkTemplateStore.service,
                                  account: String = MTSLinkTemplateStore.account) -> Bool {
        guard !defaults.bool(forKey: permanentCheckKey) else { return false }
        defaults.set(true, forKey: permanentCheckKey)
        guard KeychainHelper.get(service: service, account: account) != nil else { return false }
        delete(service: service, account: account)
        return true
    }

    private static func dropLegacy() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: legacyCaptureKey)
        if dropUncheckedOnce(defaults: defaults) {
            Task { @MainActor in
                LogStore.shared.log(.provisioning,
                    "MTS Link: the saved room template was forgotten — it was learned before the app checked that a meeting is permanent and may make quick meetings, which a server cannot enter; the next \"Make a room\" runs the lesson again")
            }
        }
    }
}