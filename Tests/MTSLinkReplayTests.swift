import XCTest
@testable import olcrtc_ios

// "Make a room" for MTS Link: the pure decisions of the silent replay (which
// values the learned headers need, how they are assembled, what the answer
// means) and the maker that falls back to the sheet. The offscreen web view
// itself is integration-only (it needs a signed-in page).

@MainActor
final class MTSLinkReplayTests: XCTestCase {

    private let owner = "100200300"

    private func template(headers: [MTSLinkHeader] = [],
                          eventPath: [MTSLinkJSON.Step]? = [.key("data"), .key("id")],
                          linkPath: [MTSLinkJSON.Step]? = nil) -> MTSLinkTemplate {
        MTSLinkTemplate(method: "POST", url: "https://my.mts-link.ru/api/events",
                        contentType: "application/json", payload: MTSLinkPayload(kind: .json, text: #"{"title":"Room"}"#),
                        headers: headers, eventPath: eventPath, linkPath: linkPath,
                        owner: owner, learnedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: Headers from provenance

    func testHeadersAreRebuiltFromTheirSources() {
        let headers = [
            MTSLinkHeader(name: "Content-Type", kind: .literal, value: "application/json", bearer: false),
            MTSLinkHeader(name: "Authorization", kind: .cookie, value: "token", bearer: true),
            MTSLinkHeader(name: "X-Local", kind: .local, value: "auth", bearer: false),
            MTSLinkHeader(name: "X-Session", kind: .session, value: "sid", bearer: false),
            MTSLinkHeader(name: "X-Csrf-Token", kind: .seen, value: "X-Csrf-Token", bearer: false),
        ]
        let sources = MTSLinkReplayRules.Sources(
            cookies: ["token": "c-value"], local: ["auth": "l-value"], session: ["sid": "s-value"],
            seen: ["x-csrf-token": "seen-value"])
        guard case .success(let out) = MTSLinkReplayRules.assemble(headers, from: sources) else {
            return XCTFail("every source is there")
        }
        XCTAssertEqual(out["Content-Type"], "application/json")
        XCTAssertEqual(out["Authorization"], "Bearer c-value")
        XCTAssertEqual(out["X-Local"], "l-value")
        XCTAssertEqual(out["X-Session"], "s-value")
        XCTAssertEqual(out["X-Csrf-Token"], "seen-value")
    }

    func testASeenBearerValueIsTakenAsTheWholeHeader() {
        let header = MTSLinkHeader(name: "Authorization", kind: .seen, value: "Authorization", bearer: true)
        let sources = MTSLinkReplayRules.Sources(seen: ["authorization": "Bearer from-the-page"])
        XCTAssertEqual(MTSLinkReplayRules.assemble([header], from: sources),
                       .success(["Authorization": "Bearer from-the-page"]))
    }

    func testAMissingTokenAbortsInsteadOfSendingWithoutOne() {
        let headers = [MTSLinkHeader(name: "Content-Type", kind: .literal, value: "application/json", bearer: false),
                       MTSLinkHeader(name: "X-Auth-Token", kind: .seen, value: "X-Auth-Token", bearer: false)]
        XCTAssertEqual(MTSLinkReplayRules.assemble(headers, from: MTSLinkReplayRules.Sources()),
                       .failure(.missingToken("X-Auth-Token")))
        // An empty value is as good as none.
        XCTAssertEqual(MTSLinkReplayRules.assemble(
            headers, from: MTSLinkReplayRules.Sources(seen: ["x-auth-token": ""])),
                       .failure(.missingToken("X-Auth-Token")))
        for kind in [MTSLinkProvenance.Kind.cookie, .local, .session] {
            let header = MTSLinkHeader(name: "Authorization", kind: kind, value: "k", bearer: false)
            XCTAssertEqual(MTSLinkReplayRules.assemble([header], from: MTSLinkReplayRules.Sources()),
                           .failure(.missingToken("Authorization")), kind.rawValue)
        }
        // No header at all is fine.
        XCTAssertEqual(MTSLinkReplayRules.assemble([], from: MTSLinkReplayRules.Sources()), .success([:]))
    }

    func testOnlyTheNamesTheTemplateNeedsAreAskedFor() {
        let headers = [
            MTSLinkHeader(name: "Accept", kind: .literal, value: "*/*", bearer: false),
            MTSLinkHeader(name: "Authorization", kind: .cookie, value: "token", bearer: true),
            MTSLinkHeader(name: "X-Local", kind: .local, value: "auth", bearer: false),
            MTSLinkHeader(name: "X-Session", kind: .session, value: "sid", bearer: false),
            MTSLinkHeader(name: "X-Csrf-Token", kind: .seen, value: "X-Csrf-Token", bearer: false),
        ]
        let wanted = MTSLinkReplayRules.wanted(for: headers)
        XCTAssertEqual(wanted["cookies"], ["token"])
        XCTAssertEqual(wanted["local"], ["auth"])
        XCTAssertEqual(wanted["session"], ["sid"])
        XCTAssertEqual(wanted["seen"], ["x-csrf-token"])
    }

    // MARK: The page it ended on

    func testASignInPageMeansTheSessionIsDead() {
        for url in ["https://my.mts-link.ru/login", "https://my.mts-link.ru/sign-in?next=/",
                    "https://my.mts-link.ru/registration", "https://login.mts.ru/amserver/UI/Login",
                    "https://id.mts.ru/auth/realms/x", "https://my.mts-link.ru/auth/login"] {
            XCTAssertTrue(MTSLinkReplayRules.isSignedOutURL(url), url)
        }
        for url in ["https://my.mts-link.ru/", "https://my.mts-link.ru/cabinet/events",
                    "https://my.mts-link.ru/j/100200300/400500600700/stream-new/70080090010"] {
            XCTAssertFalse(MTSLinkReplayRules.isSignedOutURL(url), url)
        }
    }

    // MARK: What the answer means

    func testTheAnswerBecomesARoom() {
        let t = template()
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 201, text: #"{"data":{"id":400500600701}}"#,
                                                    template: t, current: ""),
                       .success("https://my.mts-link.ru/j/\(owner)/400500600701"))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: #"{"data":{"id":"400500600701"}}"#,
                                                    template: t, current: "https://my.mts-link.ru/j/\(owner)/400500600700"),
                       .success("https://my.mts-link.ru/j/\(owner)/400500600701"))
    }

    func testTheRoomThatIsAlreadyCurrentIsAFailure() {
        let t = template()
        let answer = #"{"data":{"id":400500600701}}"#
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: answer, template: t,
                                                    current: "https://my.mts-link.ru/j/\(owner)/400500600701"),
                       .failure(.sameRoom))
        // The hint and the owner are no part of the room.
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: answer, template: t,
                                                    current: "https://my.mts-link.ru/j/supportwebinar/400500600701?ice=tcp"),
                       .failure(.sameRoom))
    }

    func testStatusesMapToTheFailuresTheCallersAreBuiltFor() {
        let t = template()
        let ok = #"{"data":{"id":400500600701}}"#
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 401, text: "", template: t, current: ""),
                       .failure(.rejected(status: 401, head: "")))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 403, text: ok, template: t, current: ""),
                       .failure(.rejected(status: 403, head: ok)))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 429, text: "", template: t, current: ""),
                       .failure(.rateLimited))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 503, text: "", template: t, current: ""),
                       .failure(.rateLimited))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 500, text: "", template: t, current: ""),
                       .failure(.serviceError(status: 500)))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 404, text: ok, template: t, current: ""),
                       .failure(.serviceError(status: 404)))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: #"{"data":{}}"#, template: t, current: ""),
                       .failure(.malformedResponse))
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: "<html>", template: t, current: ""),
                       .failure(.malformedResponse))
    }

    func testTheLinkRecipeWorksToo() {
        let t = template(eventPath: nil, linkPath: [.key("url")])
        let answer = #"{"url":"https:\/\/my.mts-link.ru\/j\/100200300\/400500600702\/stream-new\/70080090010"}"#
        XCTAssertEqual(MTSLinkReplayRules.interpret(status: 200, text: answer, template: t, current: ""),
                       .success("https://my.mts-link.ru/j/100200300/400500600702"))
    }

    func testErrorsNameAReasonWithoutAValue() {
        XCTAssertTrue(MTSLinkRoomError.sessionRejected.needsSignIn)
        XCTAssertFalse(MTSLinkRoomError.missingToken("Authorization").needsSignIn)
        XCTAssertFalse(MTSLinkRoomError.sameRoom.needsSignIn)
        XCTAssertEqual(MTSLinkRoomError.missingToken("Authorization").logText, "no value for the header Authorization")
        XCTAssertTrue(MTSLinkRoomError.rejected(status: 403, head: "").needsSignIn)
        for error in [MTSLinkRoomError.missingToken("X"), .sameRoom, .timedOut, .sessionRejected,
                      .rejected(status: 403, head: "limit"),
                      .malformedResponse, .noCreateRequest, .noSession, .rateLimited, .networkUnavailable,
                      .serviceError(status: 500)] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
            XCTAssertFalse(error.logText.isEmpty, "\(error)")
        }
    }

    // MARK: The maker

    func testTheMakerOpensTheSheetWhenNothingIsLearned() async {
        let saved = MTSLinkTemplateStore.current
        defer { MTSLinkTemplateStore.current = saved }
        MTSLinkTemplateStore.current = nil

        let maker = MTSLinkRoomMaker()
        let make = Task { await maker.makeRoom(current: "") }
        var waited = 0
        while maker.request == nil && waited < 2_000 { await Task.yield(); waited += 1 }
        XCTAssertNotNil(maker.request)
        XCTAssertFalse((maker.request?.reason ?? "").isEmpty, "the sheet says why it is open")
        XCTAssertTrue(maker.busy)

        maker.deliver("https://my.mts-link.ru/j/100200300/400500600701")
        let room = await make.value
        XCTAssertEqual(room, "https://my.mts-link.ru/j/100200300/400500600701")
        maker.sheetDismissed()   // the sheet going away after a delivery changes nothing
        XCTAssertFalse(maker.busy)
    }

    func testClosingTheSheetWithoutARoomGivesNothing() async {
        let saved = MTSLinkTemplateStore.current
        defer { MTSLinkTemplateStore.current = saved }
        MTSLinkTemplateStore.current = nil

        let maker = MTSLinkRoomMaker()
        let make = Task { await maker.makeRoom(current: "") }
        var waited = 0
        while maker.request == nil && waited < 2_000 { await Task.yield(); waited += 1 }
        maker.sheetDismissed()
        let room = await make.value
        XCTAssertNil(room)
    }

    func testTheCanCreateGateNeedsATemplate() {
        let saved = MTSLinkTemplateStore.current
        defer { MTSLinkTemplateStore.current = saved }
        MTSLinkTemplateStore.current = nil
        XCTAssertFalse(MTSLinkRoomService.canCreateRooms)
        XCTAssertFalse(MTSLinkRoomService.lessonReason().isEmpty)
    }
}
