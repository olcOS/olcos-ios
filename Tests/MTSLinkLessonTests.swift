import XCTest
@testable import olcrtc_ios

// How the app learns to make an MTS Link meeting: the owner makes one by hand in
// the sign-in sheet, presses Finish, and the app analyses what that session
// recorded. Pure functions on synthetic captures — no network, no web view. All
// ids are made up (owner 100200300, events 400500600xxx, session 700800900100).

@MainActor
final class MTSLinkLessonTests: XCTestCase {

    private let owner = "100200300"
    private let session = "70080090010"

    // MARK: Fixtures

    private func call(_ id: Int, at: TimeInterval, method: String = "POST",
                      url: String = "https://my.mts-link.ru/api/events",
                      headers: [String: String] = [:], body: String = #"{"title":"Room"}"#,
                      status: Int = 201, response: String) -> MTSLinkLessonCall {
        MTSLinkLessonCall(id: id, at: at,
                          request: CapturedRequest(method: method, url: url, headers: headers, body: body),
                          bodyBytes: body.utf8.count, status: status, response: response)
    }

    private func page(_ event: String, at: TimeInterval,
                      source: MTSLinkSighting.Source = .navigation) -> [MTSLinkSighting] {
        MTSLinkLesson.sightings(in: "https://my.mts-link.ru/j/\(owner)/\(event)/stream-new/\(session)?x=1#top",
                                at: at, source: source)
    }

    private func created(_ event: String) -> String {
        #"{"data":{"id":\#(event),"title":"Room"}}"#
    }

    // MARK: Page URL shapes

    func testTheEventIsTheSecondNumberAfterJ() {
        let sighted = MTSLinkLesson.sightings(
            in: "https://my.mts-link.ru/j/100200300/40050060070/stream-new/70080090010?utm=x#frag",
            at: 1, source: .navigation)
        XCTAssertEqual(sighted.count, 1)
        XCTAssertEqual(sighted.first?.event, "40050060070")
        XCTAssertEqual(sighted.first?.owner, "100200300")
        XCTAssertEqual(sighted.first?.link, "https://my.mts-link.ru/j/100200300/40050060070")

        for tail in ["", "/session/55", "/stream-new/70080090010", "/a/b/c", "?q=1", "#x"] {
            let again = MTSLinkLesson.sightings(in: "https://my.mts-link.ru/j/100200300/40050060070" + tail,
                                                at: 1, source: .page)
            XCTAssertEqual(again.map(\.event), ["40050060070"], tail)
        }
        // An alias owner reads as 0; the event is still the second segment.
        let alias = MTSLinkLesson.sightings(in: "https://my.mts-link.ru/j/supportwebinar/40050060070/stream-new/1",
                                            at: 1, source: .navigation)
        XCTAssertEqual(alias.first?.owner, "0")
        XCTAssertEqual(alias.first?.event, "40050060070")
        XCTAssertEqual(MTSLinkRoom.owner(of: "https://my.mts-link.ru/j/100200300/40050060070/stream-new/1"),
                       "100200300")
        XCTAssertTrue(MTSLinkLesson.sightings(in: "https://my.mts-link.ru/cabinet/events", at: 1,
                                              source: .navigation).isEmpty)
    }

    // MARK: Finish: what the analysis finds

    func testNoMeetingWasMade() {
        let calls = [call(0, at: 1, method: "GET", status: 200, response: #"{"items":[]}"#),
                     call(1, at: 2, url: "https://my.mts-link.ru/api/stat", response: "{}")]
        XCTAssertEqual(MTSLinkLesson.analyze(calls: calls, sightings: []), .none)
        XCTAssertEqual(MTSLinkLesson.analyze(calls: [], sightings: []), .none)
    }

    func testOneMeetingMadeByACreateCall() {
        let calls = [call(0, at: 1, method: "GET", status: 200, response: "{}"),
                     call(1, at: 2, response: created("400500600701"))]
        let sightings = page("400500600701", at: 3)
        guard case .one(let meeting) = MTSLinkLesson.analyze(calls: calls, sightings: sightings) else {
            return XCTFail("expected one meeting")
        }
        XCTAssertEqual(meeting.event, "400500600701")
        XCTAssertEqual(meeting.owner, owner)
        XCTAssertEqual(meeting.link, "https://my.mts-link.ru/j/\(owner)/400500600701")
        XCTAssertEqual(meeting.createCall, 1)
        XCTAssertTrue(meeting.madeByCall)
        // …and the template comes from that call alone.
        guard case .success(let template)? = MTSLinkLesson.template(for: meeting, calls: calls) else {
            return XCTFail("expected a template")
        }
        XCTAssertEqual(template.eventPath, [.key("data"), .key("id")])
        XCTAssertEqual(template.owner, owner)
        XCTAssertEqual(template.method, "POST")
        XCTAssertEqual(template.room(fromResponse: created("400500600799")),
                       "https://my.mts-link.ru/j/\(owner)/400500600799")
    }

    func testTwoMeetingsAreNotLearnedFrom() {
        let calls = [call(0, at: 2, response: created("400500600701")),
                     call(1, at: 20, response: created("400500600702"))]
        let sightings = page("400500600701", at: 3) + page("400500600702", at: 21)
        guard case .several(let meetings) = MTSLinkLesson.analyze(calls: calls, sightings: sightings) else {
            return XCTFail("expected several meetings")
        }
        XCTAssertEqual(meetings.map(\.event), ["400500600701", "400500600702"])
    }

    func testACreatedMeetingAndAnotherOneTheLastPageShowedAreBothListed() {
        let calls = [call(0, at: 2, response: created("400500600701"))]
        let sightings = page("400500600701", at: 3) + page("400500600709", at: 30)
        guard case .several(let meetings) = MTSLinkLesson.analyze(calls: calls, sightings: sightings) else {
            return XCTFail("expected several meetings")
        }
        XCTAssertEqual(Set(meetings.map(\.event)), ["400500600701", "400500600709"])
    }

    func testAListThatMentionsAnOldMeetingIsNotTheCreateCall() {
        let list = call(0, at: 1, method: "GET", status: 200,
                        response: #"{"items":[{"id":400500600703,"title":"Old"}]}"#)
        let sightings = page("400500600703", at: 5)
        XCTAssertTrue(MTSLinkLesson.candidates(calls: [list], sightings: sightings).isEmpty)
        guard case .one(let meeting) = MTSLinkLesson.analyze(calls: [list], sightings: sightings) else {
            return XCTFail("the page did show a meeting")
        }
        XCTAssertFalse(meeting.madeByCall, "a page that merely showed a meeting teaches nothing")
        XCTAssertNil(MTSLinkLesson.template(for: meeting, calls: [list]))
    }

    func testAnUpdateOfAnOldMeetingIsNotACreateCall() {
        // The request carries the meeting's id itself: it changed that meeting.
        let update = call(0, at: 1, method: "PUT", body: #"{"id":400500600704,"title":"New name"}"#,
                          status: 200, response: created("400500600704"))
        let sightings = page("400500600704", at: 2)
        XCTAssertTrue(MTSLinkLesson.candidates(calls: [update], sightings: sightings).isEmpty)
    }

    func testAMeetingShownBeforeTheCallIsNotItsWork() {
        let calls = [call(0, at: 10, response: created("400500600705"))]
        let sightings = page("400500600705", at: 1, source: .page)
        XCTAssertTrue(MTSLinkLesson.candidates(calls: calls, sightings: sightings).isEmpty)
        XCTAssertEqual(MTSLinkLesson.analyze(calls: calls, sightings: sightings), .none)
    }

    func testAMeetingThatShowsUpTooLateIsNotANumericCandidate() {
        let calls = [call(0, at: 2, response: created("400500600706"))]
        let late = page("400500600706", at: 2 + MTSLinkLesson.numericWindow + 5)
        XCTAssertTrue(MTSLinkLesson.candidates(calls: calls, sightings: late).isEmpty)
        let inTime = page("400500600706", at: 2 + MTSLinkLesson.numericWindow - 1)
        XCTAssertEqual(MTSLinkLesson.candidates(calls: calls, sightings: inTime).count, 1)
    }

    func testAnAnswerThatListsManyNumbersIsNotACreateCall() {
        let ids = (0..<9).map { "40050060080\($0)" }
        let response = "{\"ids\":[" + ids.joined(separator: ",") + "]}"
        let calls = [call(0, at: 2, response: response)]
        XCTAssertTrue(MTSLinkLesson.candidates(calls: calls, sightings: page(ids[3], at: 3)).isEmpty)
    }

    func testOnlyMutatingCallsThatSucceededAreCandidates() {
        for method in ["GET", "DELETE", "HEAD", "OPTIONS"] {
            XCTAssertFalse(MTSLinkLesson.isMutating(method), method)
        }
        for method in ["POST", "put", "Patch"] {
            XCTAssertTrue(MTSLinkLesson.isMutating(method), method)
        }
        let failed = call(0, at: 2, status: 403, response: created("400500600707"))
        XCTAssertTrue(MTSLinkLesson.candidates(calls: [failed], sightings: page("400500600707", at: 3)).isEmpty)
        let get = call(0, at: 2, method: "GET", status: 200, response: created("400500600707"))
        XCTAssertTrue(MTSLinkLesson.candidates(calls: [get], sightings: page("400500600707", at: 3)).isEmpty)
    }

    func testTheAnswerMayCarryTheJoinLinkWithEscapedSlashes() {
        let response = #"{"url":"https:\/\/my.mts-link.ru\/j\/100200300\/400500600708\/stream-new\/70080090010"}"#
        let calls = [call(0, at: 2, response: response)]
        let sightings = MTSLinkLesson.sightings(in: "https://my.mts-link.ru/j/100200300/400500600708",
                                                at: 4, source: .page)
        guard case .one(let meeting) = MTSLinkLesson.analyze(calls: calls, sightings: sightings) else {
            return XCTFail("expected one meeting")
        }
        XCTAssertEqual(meeting.event, "400500600708")
        guard case .success(let template)? = MTSLinkLesson.template(for: meeting, calls: calls) else {
            return XCTFail("expected a template")
        }
        XCTAssertNil(template.eventPath)
        XCTAssertEqual(template.linkPath, [.key("url")])
        XCTAssertEqual(template.room(fromResponse: response), "https://my.mts-link.ru/j/100200300/400500600708")
    }

    func testARejectedMeetingIsLeftOutOfTheNextAnalysis() {
        let calls = [call(0, at: 2, response: created("400500600701"))]
        let sightings = page("400500600701", at: 3)
        XCTAssertEqual(MTSLinkLesson.analyze(calls: calls, sightings: sightings,
                                             dismissed: ["400500600701"]), .none)
    }

    func testWithoutNavigationThePageTextAfterAChangeIsTheOnlyHint() {
        let calls = [call(0, at: 10, url: "https://my.mts-link.ru/api/stat", response: "{}")]
        let old = page("400500600710", at: 1, source: .page)
        let fresh = page("400500600711", at: 12, source: .page)
        guard case .one(let meeting) = MTSLinkLesson.analyze(calls: calls, sightings: old + fresh) else {
            return XCTFail("expected one meeting")
        }
        XCTAssertEqual(meeting.event, "400500600711")
        XCTAssertFalse(meeting.madeByCall)
    }

    // MARK: The template

    func testTheTemplateKeepsOnlyWhereCredentialsComeFrom() {
        let headers = ["Authorization": "olc:cookie+bearer:token",
                       "Content-Type": "application/json",
                       "X-Csrf-Token": "olc:seen:X-Csrf-Token",
                       "Accept": "application/json",
                       "Cookie": "olc:cookie:sid",
                       "X-Api-Token": "fixture-secret-value"]
        let made = call(0, at: 2, headers: headers, response: created("400500600701"))
        guard case .success(let template) = MTSLinkTemplate.build(from: made, event: "400500600701",
                                                                  owner: owner, now: Date(timeIntervalSince1970: 0))
        else { return XCTFail("expected a template") }
        let byName = Dictionary(uniqueKeysWithValues: template.headers.map { ($0.name, $0) })
        XCTAssertEqual(byName["Authorization"], MTSLinkHeader(name: "Authorization", kind: .cookie,
                                                              value: "token", bearer: true))
        XCTAssertEqual(byName["X-Csrf-Token"]?.kind, .seen)
        XCTAssertEqual(byName["X-Csrf-Token"]?.value, "X-Csrf-Token")
        XCTAssertEqual(byName["Content-Type"]?.kind, .literal)
        XCTAssertEqual(byName["Accept"]?.value, "application/json")
        XCTAssertNil(byName["Cookie"], "the browser sends the cookies itself")
        // A credential-named header whose value was not replaced is never kept.
        XCTAssertEqual(byName["X-Api-Token"]?.kind, .seen)
        let stored = String(decoding: (try? JSONEncoder().encode(template)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("fixture-secret-value"), stored)
        XCTAssertEqual(template.contentType, "application/json")
        XCTAssertEqual(template.headers.map(\.name), template.headers.map(\.name).sorted())
    }

    func testAnAliasOwnerBecomesZeroInTheTemplate() {
        let sighted = MTSLinkLesson.sightings(in: "https://my.mts-link.ru/j/supportwebinar/400500600701/stream-new/1",
                                              at: 3, source: .navigation)
        let calls = [call(0, at: 2, response: created("400500600701"))]
        guard case .one(let meeting) = MTSLinkLesson.analyze(calls: calls, sightings: sighted),
              case .success(let template)? = MTSLinkLesson.template(for: meeting, calls: calls) else {
            return XCTFail("expected a template")
        }
        XCTAssertEqual(template.owner, "0")
        XCTAssertEqual(template.room(fromResponse: created("400500600702")), "https://my.mts-link.ru/j/0/400500600702")
    }

    func testATemplateIsOnlyBuiltFromARequestItCanReplay() {
        let good = call(0, at: 2, response: created("400500600701"))
        var foreign = good
        foreign.request.url = "https://evil.example/api/events"
        XCTAssertEqual(MTSLinkTemplate.build(from: foreign, event: "400500600701", owner: owner),
                       .failure(.foreignHost))
        var plainHTTP = good
        plainHTTP.request.url = "http://my.mts-link.ru/api/events"
        XCTAssertEqual(MTSLinkTemplate.build(from: plainHTTP, event: "400500600701", owner: owner),
                       .failure(.foreignHost))
        var get = good
        get.request.method = "GET"
        XCTAssertEqual(MTSLinkTemplate.build(from: get, event: "400500600701", owner: owner),
                       .failure(.notMutating))
        var form = good
        form.request.body = "[object FormData]"
        XCTAssertEqual(MTSLinkTemplate.build(from: form, event: "400500600701", owner: owner),
                       .failure(.bodyUnsupported("a body object")))
        var filePart = good
        filePart.raw = MTSLinkRawRequest(url: filePart.request.url, headers: [:], payload: MTSLinkPayload(),
                                         unsupported: "a file part in the form")
        XCTAssertEqual(MTSLinkTemplate.build(from: filePart, event: "400500600701", owner: owner),
                       .failure(.bodyUnsupported("a file part in the form")))
        var big = good
        big.bodyBytes = MTSLinkRawRequest.maxBytes + 1
        XCTAssertEqual(MTSLinkTemplate.build(from: big, event: "400500600701", owner: owner),
                       .failure(.bodyTooLarge))
        let noPath = call(0, at: 2, response: #"{"ok":true}"#)
        XCTAssertEqual(MTSLinkTemplate.build(from: noPath, event: "400500600701", owner: owner),
                       .failure(.noPathInResponse))
    }

    func testTheTemplateURLKeepsItsPathAndQueryAndLosesOnlyTheFragment() {
        XCTAssertEqual(MTSLinkTemplate.cleanURL("https://my.mts-link.ru/api/events?lang=ru&token=abc#x"),
                       "https://my.mts-link.ru/api/events?lang=ru&token=abc")
        XCTAssertEqual(MTSLinkTemplate.cleanURL("https://my.mts-link.ru/api/events"),
                       "https://my.mts-link.ru/api/events")
    }

    func testAnAnswerWithoutTheRecipesFieldGivesNoRoom() {
        let template = MTSLinkTemplate(method: "POST", url: "https://my.mts-link.ru/api/events",
                                       contentType: "", payload: MTSLinkPayload(), headers: [],
                                       eventPath: [.key("data"), .key("id")], linkPath: nil,
                                       owner: owner, learnedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(template.room(fromResponse: #"{"data":{}}"#))
        XCTAssertNil(template.room(fromResponse: "not json"))
        XCTAssertNil(template.room(fromResponse: #"{"data":{"id":12}}"#), "a short number is no event id")
        XCTAssertNil(template.room(fromResponse: #"{"data":{"id":true}}"#))
        XCTAssertEqual(template.room(fromResponse: #"{"data":{"id":"400500600701"}}"#),
                       "https://my.mts-link.ru/j/\(owner)/400500600701", "a string id works too")
    }

    func testATemplateRoundTripsThroughItsStore() {
        let saved = MTSLinkTemplateStore.current
        defer { MTSLinkTemplateStore.current = saved }
        let template = MTSLinkTemplate(
            method: "POST", url: "https://my.mts-link.ru/api/events", contentType: "application/json",
            payload: MTSLinkPayload(kind: .json, text: "{}"),
            headers: [MTSLinkHeader(name: "Authorization", kind: .local, value: "k", bearer: true)],
            eventPath: [.key("items"), .index(0), .key("id")], linkPath: nil,
            owner: owner, learnedAt: Date(timeIntervalSince1970: 1_000))
        MTSLinkTemplateStore.current = template
        XCTAssertEqual(MTSLinkTemplateStore.current, template)
        MTSLinkTemplateStore.forget()
        XCTAssertNil(MTSLinkTemplateStore.current)
    }

    // MARK: Provenance

    func testTheProvenanceMarkerParser() {
        XCTAssertEqual(MTSLinkProvenance.parse("olc:cookie:sid"),
                       MTSLinkProvenance.Marker(kind: .cookie, name: "sid", bearer: false))
        XCTAssertEqual(MTSLinkProvenance.parse("olc:local+bearer:auth:token"),
                       MTSLinkProvenance.Marker(kind: .local, name: "auth:token", bearer: true))
        XCTAssertEqual(MTSLinkProvenance.parse("olc:session:k")?.kind, .session)
        XCTAssertEqual(MTSLinkProvenance.parse("olc:seen:x-csrf")?.kind, .seen)
        for bad in ["", "plain", "olc:", "olc:cookie", "olc:cookie:", "olc:literal:x", "olc:bogus:x",
                    "olc:cookie+x:n", "olc:cookie+bearer+bearer:n", "Bearer abc"] {
            XCTAssertNil(MTSLinkProvenance.parse(bad), bad)
        }
        let marker = MTSLinkProvenance.marker(kind: .session, name: "a:b", bearer: true)
        XCTAssertEqual(MTSLinkProvenance.parse(marker),
                       MTSLinkProvenance.Marker(kind: .session, name: "a:b", bearer: true))
    }

    func testWhichHeadersAreCredentials() {
        for name in ["Authorization", "x-auth-token", "X-CSRF-Token", "x-xsrf-token", "X-Api-Key", "token",
                     "X-Session-Id"] {
            XCTAssertTrue(MTSLinkProvenance.isCredentialName(name), name)
        }
        for name in ["Content-Type", "Accept", "X-Requested-With", "Accept-Language"] {
            XCTAssertFalse(MTSLinkProvenance.isCredentialName(name), name)
        }
        XCTAssertTrue(MTSLinkProvenance.looksLikeSecret("eyJhbGciOi.abc.def"))
        XCTAssertTrue(MTSLinkProvenance.looksLikeSecret("Bearer eyJhbGciOi.abc.def"))
        XCTAssertFalse(MTSLinkProvenance.looksLikeSecret("application/json"))
        XCTAssertNil(MTSLinkHeader.make(name: "Cookie", reported: "x"))
        XCTAssertNil(MTSLinkHeader.make(name: "Origin", reported: "https://my.mts-link.ru"))
        XCTAssertEqual(MTSLinkHeader.make(name: "X-Custom", reported: "eyJabc.def.ghi")?.kind, .seen)
    }

    func testTheLogNeverCarriesAValue() {
        let header = MTSLinkHeader(name: "Authorization", kind: .cookie, value: "token", bearer: true)
        XCTAssertEqual(header.sourceSummary, "Authorization=cookie(token)+bearer")
        XCTAssertEqual(MTSLinkHeader(name: "Accept", kind: .literal, value: "application/json", bearer: false)
            .sourceSummary, "Accept=literal")
    }

    // MARK: JSON paths

    func testJSONPaths() throws {
        let json = try XCTUnwrap(MTSLinkJSON.parse(
            #"{"data":{"id":400500600701,"items":[{"id":"a"},{"ref":"400500600702"}],"flag":true}}"#))
        XCTAssertEqual(MTSLinkJSON.string(at: [.key("data"), .key("id")], in: json), "400500600701")
        XCTAssertEqual(MTSLinkJSON.string(at: [.key("data"), .key("items"), .index(1), .key("ref")], in: json),
                       "400500600702")
        XCTAssertEqual(MTSLinkJSON.string(at: [.key("data"), .key("items"), .index(0), .key("id")], in: json), "a")
        XCTAssertNil(MTSLinkJSON.string(at: [.key("data"), .key("flag")], in: json), "a boolean is no id")
        XCTAssertNil(MTSLinkJSON.value(at: [.key("data"), .key("items"), .index(5)], in: json))
        XCTAssertNil(MTSLinkJSON.value(at: [.key("nope")], in: json))
        // A number and a string both match the id; the shallowest wins.
        XCTAssertEqual(MTSLinkJSON.paths(of: "400500600701", in: json), [[.key("data"), .key("id")]])
        XCTAssertEqual(MTSLinkJSON.paths(of: "400500600702", in: json),
                       [[.key("data"), .key("items"), .index(1), .key("ref")]])
        XCTAssertEqual(MTSLinkJSON.describe([.key("data"), .key("items"), .index(1), .key("ref")]),
                       "data.items[1].ref")
        let both = try XCTUnwrap(MTSLinkJSON.parse(#"{"a":{"b":{"id":"5"}},"id":"5","z":"5"}"#))
        XCTAssertEqual(MTSLinkJSON.paths(of: "5", in: both).first, [.key("id")])
    }

    // MARK: Scrubbing

    func testBodiesHeadersAndAnswersAreScrubbed() {
        let body = #"{"title":"Room","access_token":"fixture-token","password":"fixture-pass","jwt":"eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.c2lnbmF0dXJl"}"#
        let clean = MTSLinkScrub.text(body, limit: 4096)
        XCTAssertFalse(clean.contains("fixture-token"), clean)
        XCTAssertFalse(clean.contains("fixture-pass"), clean)
        XCTAssertFalse(clean.contains("eyJhbGci"), clean)
        XCTAssertTrue(clean.contains("Room"))
        let session = MTSLinkScrub.text(#"{"sessionId":"700800900100","csrf":"c-fixture"}"#, limit: 4096)
        XCTAssertFalse(session.contains("c-fixture"), session)
        XCTAssertLessThanOrEqual(MTSLinkScrub.text(String(repeating: "a", count: 9_000), limit: 100).utf8.count, 100)

        let request = CapturedRequest.scrubbed(
            method: "post", url: "https://my.mts-link.ru/api/events",
            headers: ["Authorization": "olc:cookie+bearer:token",
                      "X-Auth-Token": "fixture-token",
                      "X-Custom-Secret": "fixture-secret",
                      "Accept": "application/json"],
            body: body)
        XCTAssertEqual(request.headers["Authorization"], "olc:cookie+bearer:token", "a marker is not a value")
        XCTAssertEqual(request.headers["X-Auth-Token"], "<redacted>")
        XCTAssertEqual(request.headers["X-Custom-Secret"], "<redacted>")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertFalse(request.body.contains("fixture-token"))
        XCTAssertEqual(request.summary, "POST https://my.mts-link.ru/api/events")
        XCTAssertEqual(CapturedRequest(method: "GET", url: "https://my.mts-link.ru/a?token=zzz",
                                       headers: [:], body: "").summary, "GET https://my.mts-link.ru/a")
    }

    // MARK: The capture

    func testNothingIsLearnedBeforeFinish() throws {
        let saved = MTSLinkTemplateStore.current
        defer { MTSLinkTemplateStore.current = saved }
        MTSLinkTemplateStore.current = nil
        var now: TimeInterval = 100
        let capture = MTSLinkRequestCapture(clock: { now })

        now = 101
        capture.record(method: "POST", url: "https://my.mts-link.ru/api/events",
                       headers: ["Authorization": "Bearer fixture-token", "Content-Type": "application/json"],
                       body: #"{"title":"Room"}"#, status: 201, response: created("400500600701"))
        XCTAssertFalse(capture.meetingHint, "no page has shown the meeting yet")
        now = 102
        capture.recordNavigation(url: "https://my.mts-link.ru/j/\(owner)/400500600701/stream-new/\(session)?x=1")

        XCTAssertTrue(capture.meetingHint, "a passive hint only")
        XCTAssertNil(MTSLinkTemplateStore.current, "nothing is saved before the owner confirms")

        guard case .one(let meeting) = capture.analysis() else { return XCTFail("expected one meeting") }
        XCTAssertEqual(meeting.event, "400500600701")
        guard case .success(let template)? = capture.template(for: meeting) else {
            return XCTFail("expected a template")
        }
        XCTAssertEqual(template.headers.first { $0.name == "Authorization" }?.kind, .seen)

        let dump = capture.dump()
        XCTAssertFalse(dump.contains("fixture-token"), dump)
        XCTAssertTrue(dump.contains("POST https://my.mts-link.ru/api/events → 201"), dump)
        XCTAssertFalse(dump.contains("x=1"), "a query may carry a token")

        capture.dismiss(event: "400500600701")
        XCTAssertFalse(capture.meetingHint)
        XCTAssertEqual(capture.analysis(), .none)
    }

    func testStaticAssetsAreNotCaptured() {
        XCTAssertFalse(MTSLinkRequestCapture.isInteresting("https://my.mts-link.ru/app.js"))
        XCTAssertFalse(MTSLinkRequestCapture.isInteresting("https://my.mts-link.ru/style.css?v=2"))
        XCTAssertTrue(MTSLinkRequestCapture.isInteresting("https://gw.mts-link.ru/api/events"))
    }
}
