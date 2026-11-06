import XCTest
@testable import olcrtc_ios

// What the replay sends is what the page sent: the template keeps the request
// as the page sent it (URL, query, body of its own kind), with only the parts
// equal to a cookie / storage value turned into markers that are resolved at
// replay; the scrubbed copy is what the list, the log and the dump show. The
// page-side marker computation (MTSLinkHook) is JavaScript and integration-only;
// everything after the message arrives is pure and pinned here. All ids are
// made up.

@MainActor
final class MTSLinkFidelityTests: XCTestCase {

    private let owner = "100200300"
    private let uuid = "123e4567-e89b-12d3-a456-426614174000"
    private let answer = #"{"data":{"id":400500600701}}"#

    private func template(url: String = "https://my.mts-link.ru/api/events",
                          payload: MTSLinkPayload,
                          headers: [MTSLinkHeader] = []) -> MTSLinkTemplate {
        MTSLinkTemplate(method: "POST", url: url, contentType: "", payload: payload, headers: headers,
                        eventPath: [.key("data"), .key("id")], linkPath: nil,
                        owner: owner, learnedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: The template keeps what the page sent

    func testAUUIDAndAFieldTheRedactorWouldBlankSurviveIntoTheTemplateAndTheReplay() throws {
        let hex = String(repeating: "ab", count: 32)
        let url = "https://my.mts-link.ru/api/owners/\(uuid)/events?lang=ru&folder=\(uuid)"
        let body = #"{"folder":"\#(uuid)","token":"fixture-visible-value","key":"\#(hex)","title":"Room"}"#
        let headers = ["Content-Type": "application/json", "X-Request-Id": uuid]
        let page = try XCTUnwrap(MTSLinkRawRequest.parse(["url": url, "kind": "json", "text": body],
                                                         headers: headers))

        var now: TimeInterval = 100
        let capture = MTSLinkRequestCapture(clock: { now })
        now = 101
        capture.record(method: "POST", url: url, headers: headers, body: body, status: 201,
                       response: answer, page: page)
        now = 102
        capture.recordNavigation(url: "https://my.mts-link.ru/j/\(owner)/400500600701/stream-new/70080090010")

        guard case .one(let meeting) = capture.analysis(),
              case .success(let built)? = capture.template(for: meeting) else {
            return XCTFail("expected a template")
        }
        // The template: exactly as sent — the UUID in the path, the query, the
        // token field and the 64-hex run the redactor would have blanked.
        XCTAssertEqual(built.url, url)
        XCTAssertEqual(built.payload, MTSLinkPayload(kind: .json, text: body))
        XCTAssertTrue(built.payload.text.contains("fixture-visible-value"))
        XCTAssertTrue(built.payload.text.contains(hex))
        let literal = built.headers.first { $0.name == "X-Request-Id" }
        XCTAssertEqual(literal?.kind, .literal)
        XCTAssertEqual(literal?.value, uuid, "an ordinary header value is not blanked either")

        // The display copy: scrubbed, exactly as before.
        let shown = try XCTUnwrap(capture.entries.first)
        XCTAssertFalse(shown.request.body.contains("fixture-visible-value"), shown.request.body)
        XCTAssertFalse(shown.request.body.contains(hex), shown.request.body)
        XCTAssertTrue(shown.request.body.contains("Room"))
        let dump = capture.dump()
        XCTAssertFalse(dump.contains("fixture-visible-value"), dump)
        XCTAssertFalse(dump.contains(hex), dump)

        // …and the replay arguments carry the request as sent.
        guard case .success(let resolved) = MTSLinkReplayRules.resolve(built, from: MTSLinkReplayRules.Sources()) else {
            return XCTFail("nothing to resolve")
        }
        let arguments = MTSLinkReplayRules.fetchArguments(resolved, method: built.method, timeoutMs: 5_000)
        XCTAssertEqual(arguments["url"] as? String, url)
        XCTAssertEqual(arguments["bodyKind"] as? String, "json")
        XCTAssertEqual(arguments["bodyText"] as? String, body)
        XCTAssertEqual((arguments["headers"] as? [String: String])?["X-Request-Id"], uuid)
        XCTAssertEqual((arguments["headers"] as? [String: String])?["Content-Type"], "application/json")
    }

    func testTheTemplateIsBuiltFromThePagesCopyNotTheScrubbedOne() throws {
        let body = #"{"token":"fixture-visible-value"}"#
        let scrubbed = CapturedRequest.scrubbed(method: "POST", url: "https://my.mts-link.ru/api/events",
                                                headers: [:], body: body)
        XCTAssertFalse(scrubbed.body.contains("fixture-visible-value"))
        let call = MTSLinkLessonCall(
            id: 0, at: 1, request: scrubbed, bodyBytes: body.utf8.count, status: 201, response: answer,
            raw: MTSLinkRawRequest(url: scrubbed.url, headers: [:],
                                   payload: MTSLinkPayload(kind: .json, text: body), unsupported: nil))
        guard case .success(let built) = MTSLinkTemplate.build(from: call, event: "400500600701", owner: owner) else {
            return XCTFail("expected a template")
        }
        XCTAssertEqual(built.payload.text, body)
    }

    // MARK: Markers

    func testACookieEqualValueIsAMarkerAndResolvesAtReplay() {
        let json = #"{"owner":"<<olc:cookie:sid>>","note":"a \"quoted\" <<olc:local:note>>"}"#
        let t = template(url: "https://my.mts-link.ru/api/events?sid=<<olc:cookie:sid;enc>>&x=1",
                         payload: MTSLinkPayload(kind: .json, text: json))
        XCTAssertTrue(MTSLinkURL.isMTSLink(t.url), "a marker in the query does not hide the host")
        XCTAssertEqual(MTSLinkReplayRules.wanted(for: t)["cookies"], ["sid"])
        XCTAssertEqual(MTSLinkReplayRules.wanted(for: t)["local"], ["note"])
        XCTAssertEqual(MTSLinkReplayRules.markerCount(t), 3)

        let sources = MTSLinkReplayRules.Sources(cookies: ["sid": "abc def/16-chars-long"],
                                                 local: ["note": "line\nbreak \"q\""])
        guard case .success(let resolved) = MTSLinkReplayRules.resolve(t, from: sources) else {
            return XCTFail("every value is there")
        }
        XCTAssertEqual(resolved.url, "https://my.mts-link.ru/api/events?sid=abc%20def%2F16-chars-long&x=1")
        XCTAssertEqual(resolved.payload.text,
                       #"{"owner":"abc def/16-chars-long","note":"a \"quoted\" line\nbreak \"q\""}"#)

        // A marker the page gives no value for aborts, naming the cookie.
        XCTAssertEqual(MTSLinkReplayRules.resolve(t, from: MTSLinkReplayRules.Sources(local: ["note": "n"])),
                       .failure(.missingToken("sid")))
        XCTAssertEqual(MTSLinkReplayRules.resolve(t, from: MTSLinkReplayRules.Sources(cookies: ["sid": ""],
                                                                                      local: ["note": "n"])),
                       .failure(.missingToken("sid")))
    }

    func testAPlainTextBodyTakesItsMarkersRaw() {
        let t = template(payload: MTSLinkPayload(kind: .text, text: "sid=<<olc:cookie:sid>>&x=1"))
        guard case .success(let resolved) = MTSLinkReplayRules.resolve(
            t, from: MTSLinkReplayRules.Sources(cookies: ["sid": "a\"b"])) else { return XCTFail("resolved") }
        XCTAssertEqual(resolved.payload.text, "sid=a\"b&x=1", "no JSON escaping outside a JSON body")
    }

    func testFieldMarkersAreResolvedPerField() {
        let t = template(payload: MTSLinkPayload(kind: .urlencoded, fields: [
            .init(name: "session", value: "olc:cookie:sid"),
            .init(name: "title", value: "Room"),
            .init(name: "local", value: "olc:local:k"),
            .init(name: "odd", value: "olc:seen:x"),   // not a field marker: kept as it is
        ]))
        let sources = MTSLinkReplayRules.Sources(cookies: ["sid": "cookie-value"], local: ["k": "local-value"])
        guard case .success(let resolved) = MTSLinkReplayRules.resolve(t, from: sources) else {
            return XCTFail("resolved")
        }
        XCTAssertEqual(resolved.payload.fields.map(\.value),
                       ["cookie-value", "Room", "local-value", "olc:seen:x"])
        XCTAssertEqual(MTSLinkReplayRules.resolve(t, from: MTSLinkReplayRules.Sources()),
                       .failure(.missingToken("sid")))
    }

    // MARK: Body kinds

    func testTheKindsTheHookReports() throws {
        let headers = ["Content-Type": "text/plain"]
        let text = try XCTUnwrap(MTSLinkRawRequest.parse(["url": "https://my.mts-link.ru/a", "kind": "text",
                                                          "text": "hello"], headers: headers))
        XCTAssertEqual(text.payload, MTSLinkPayload(kind: .text, text: "hello"))
        XCTAssertNil(text.unsupported)

        let none = try XCTUnwrap(MTSLinkRawRequest.parse(["url": "https://my.mts-link.ru/a", "kind": "none"],
                                                         headers: [:]))
        XCTAssertEqual(none.payload, MTSLinkPayload())

        let form = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/a", "kind": "urlencoded",
             "fields": [["a", "1"], ["b", "two words"]]], headers: [:]))
        XCTAssertEqual(form.payload.kind, .urlencoded)
        XCTAssertEqual(form.payload.fields, [.init(name: "a", value: "1"), .init(name: "b", value: "two words")])

        let multipart = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/a", "kind": "formdata", "fields": [["a", "1"]]], headers: [:]))
        XCTAssertEqual(multipart.payload.kind, .formData)
        XCTAssertNil(multipart.unsupported)

        // A file / Blob / binary / stream part: no template, with the reason.
        let file = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/a", "kind": "unsupported", "why": "a file part in the form",
             "fields": [["a", "1"]]], headers: [:]))
        XCTAssertEqual(file.unsupported, "a file part in the form")
        let blob = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/a", "kind": "unsupported", "why": "a Blob body"], headers: [:]))
        XCTAssertEqual(blob.unsupported, "a Blob body")
        let unknown = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/a", "kind": "mystery"], headers: [:]))
        XCTAssertNotNil(unknown.unsupported)

        XCTAssertNil(MTSLinkRawRequest.parse(["kind": "text"], headers: [:]), "no URL, no request")
    }

    func testAFilePartGivesNoTemplateAndSaysWhy() throws {
        let raw = try XCTUnwrap(MTSLinkRawRequest.parse(
            ["url": "https://my.mts-link.ru/api/events", "kind": "unsupported",
             "why": "a file part in the form", "fields": [["a", "1"]]], headers: [:]))
        let call = MTSLinkLessonCall(
            id: 0, at: 1,
            request: CapturedRequest(method: "POST", url: raw.url, headers: [:], body: "a=1&f=[file]"),
            bodyBytes: 10, status: 201, response: answer, raw: raw)
        let built = MTSLinkTemplate.build(from: call, event: "400500600701", owner: owner)
        XCTAssertEqual(built, .failure(.bodyUnsupported("a file part in the form")))
        if case .failure(let failure) = built {
            XCTAssertTrue(failure.reason.contains("a file part in the form"), failure.reason)
        }
    }

    func testFormBodiesAreRebuiltAsTheSameKindInThePage() {
        let headers = [MTSLinkHeader(name: "Content-Type", kind: .literal,
                                     value: "application/x-www-form-urlencoded", bearer: false),
                       MTSLinkHeader(name: "Accept", kind: .literal, value: "application/json", bearer: false)]
        let sources = MTSLinkReplayRules.Sources(cookies: ["sid": "cookie-value"])
        for (kind, name) in [(MTSLinkPayload.Kind.urlencoded, "urlencoded"), (.formData, "formData")] {
            let t = template(payload: MTSLinkPayload(kind: kind, fields: [
                .init(name: "title", value: "Room"), .init(name: "t", value: "olc:cookie:sid")]),
                             headers: headers)
            guard case .success(let resolved) = MTSLinkReplayRules.resolve(t, from: sources) else {
                return XCTFail("resolved")
            }
            let arguments = MTSLinkReplayRules.fetchArguments(resolved, method: "POST", timeoutMs: 1_000)
            XCTAssertEqual(arguments["bodyKind"] as? String, name)
            XCTAssertEqual(arguments["fields"] as? [[String]], [["title", "Room"], ["t", "cookie-value"]])
            XCTAssertEqual(arguments["bodyText"] as? String, "")
            // The browser sets the Content-Type (and a multipart boundary) itself.
            let sent = arguments["headers"] as? [String: String]
            XCTAssertNil(sent?["Content-Type"], name)
            XCTAssertEqual(sent?["Accept"], "application/json")
        }
        // A string body keeps the Content-Type the page set.
        let text = template(payload: MTSLinkPayload(kind: .text, text: "a=b"),
                            headers: [MTSLinkHeader(name: "Content-Type", kind: .literal,
                                                    value: "application/x-www-form-urlencoded", bearer: false)])
        guard case .success(let resolved) = MTSLinkReplayRules.resolve(text, from: sources) else {
            return XCTFail("resolved")
        }
        let arguments = MTSLinkReplayRules.fetchArguments(resolved, method: "POST", timeoutMs: 1_000)
        XCTAssertEqual(arguments["bodyKind"] as? String, "text")
        XCTAssertEqual(arguments["bodyText"] as? String, "a=b")
        XCTAssertEqual((arguments["headers"] as? [String: String])?["Content-Type"],
                       "application/x-www-form-urlencoded")
    }

    func testTheReplayScriptBuildsTheSameKindOfBody() {
        let script = MTSLinkReplay.fetchScript
        XCTAssertTrue(script.contains("new URLSearchParams()"))
        XCTAssertTrue(script.contains("new FormData()"))
        XCTAssertTrue(script.contains("form.append(f[0], f[1])"))
        XCTAssertTrue(script.contains("init.body = bodyText"))
        XCTAssertFalse(script.contains("text/plain"), "a form is never forced to text/plain")
        XCTAssertFalse(script.contains("Content-Type"), "the script sets no content type of its own")
    }

    // MARK: Encoding helpers

    func testEscapingForTheirPlaces() {
        XCTAssertEqual(MTSLinkReplayRules.percentEncode("a b/c?d=e&f+g'(h)"), "a%20b%2Fc%3Fd%3De%26f%2Bg'(h)")
        XCTAssertEqual(MTSLinkReplayRules.jsonEscape("a\"b\\c\nd\u{01}"), "a\\\"b\\\\c\\nd\\u0001")
    }

    // MARK: The refusal reads with its status and head

    func testA403CarriesItsStatusAndTheScrubbedHead() {
        let t = template(payload: MTSLinkPayload())
        let cap = #"{"error":"You have reached the limit of 2 permanent meetings","access_token":"fixture-token"}"#
        let result = MTSLinkReplayRules.interpret(status: 403, text: cap, template: t, current: "")
        guard case .failure(.rejected(let status, let head)) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(status, 403)
        XCTAssertTrue(head.contains("limit of 2 permanent meetings"), head)
        XCTAssertFalse(head.contains("fixture-token"), head)
        XCTAssertFalse(head.contains("\n"))
        XCTAssertLessThanOrEqual(head.count, 160)
        XCTAssertTrue(MTSLinkRoomError.rejected(status: 403, head: head).needsSignIn,
                      "a 403 still means the sign-in, as before")
        for locale in AppLocale.allCases {
            let line = MTSLinkRoomError.rejected(status: 403, head: "limit reached").errorDescription ?? ""
            XCTAssertTrue(L10n.mtsErrRejected_fmt.localized(locale).contains("%d"), locale.rawValue)
            XCTAssertTrue(L10n.mtsErrRejected_fmt.localized(locale).contains("%@"), locale.rawValue)
            XCTAssertTrue(line.contains("403"), line)
            XCTAssertTrue(line.contains("limit reached"), line)
        }
        // A signed-out page is a different sentence from a refusal with a status.
        XCTAssertNotEqual(MTSLinkRoomError.sessionRejected.errorDescription,
                          MTSLinkRoomError.rejected(status: 403, head: "x").errorDescription)
    }

    // MARK: The Keychain

    func testTheTemplateLivesInTheKeychainNotInUserDefaults() {
        let service = "test.olcrtc.mtslink.template.\(UUID().uuidString)"
        let account = "template"
        defer { MTSLinkTemplateStore.delete(service: service, account: account) }
        let t = template(url: "https://my.mts-link.ru/api/owners/\(uuid)/events",
                         payload: MTSLinkPayload(kind: .json, text: #"{"token":"fixture-visible-value"}"#),
                         headers: [MTSLinkHeader(name: "Authorization", kind: .cookie, value: "token", bearer: true)])
        XCTAssertNil(MTSLinkTemplateStore.load(service: service, account: account))
        XCTAssertTrue(MTSLinkTemplateStore.save(t, service: service, account: account))
        XCTAssertEqual(MTSLinkTemplateStore.load(service: service, account: account), t)
        XCTAssertTrue(MTSLinkTemplateStore.save(t, service: service, account: account), "saving again replaces")
        MTSLinkTemplateStore.delete(service: service, account: account)
        XCTAssertNil(MTSLinkTemplateStore.load(service: service, account: account))
    }

    func testTheShippedStoreIsTheKeychainAndForgetsTheOlderUserDefaultsTemplate() {
        let saved = MTSLinkTemplateStore.current
        let legacyKey = "olcrtc.mtslink.template.v1"
        defer {
            MTSLinkTemplateStore.current = saved
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        MTSLinkTemplateStore.current = nil
        // An older build kept a template here, built from the scrubbed capture.
        UserDefaults.standard.set(Data("{}".utf8), forKey: legacyKey)
        XCTAssertNil(MTSLinkTemplateStore.current, "it is forgotten, never migrated")
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey))

        let t = template(payload: MTSLinkPayload(kind: .text, text: "x"))
        MTSLinkTemplateStore.current = t
        XCTAssertEqual(MTSLinkTemplateStore.current, t)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey), "nothing is written to UserDefaults")
        MTSLinkTemplateStore.forget()
        XCTAssertNil(MTSLinkTemplateStore.current)
    }
}
