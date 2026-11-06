import XCTest
@testable import olcrtc_ios

// Only a permanent MTS Link meeting reaches a server: before a meeting is used
// it is checked with the core's own first call — the event's public record —
// and only an endless meeting with a session is usable. Pure decisions on
// synthetic records; the fetch itself is integration-only (it needs the
// service). All ids are made up (owner 100200300, event 20300400500, session
// 20300400600).

@MainActor
final class MTSLinkMeetingCheckTests: XCTestCase {

    private let event = "20300400500"
    private var link: String { "https://my.mts-link.ru/j/100200300/\(event)" }
    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    private func verdict(_ status: Int, _ body: String) -> MTSLinkMeetingVerdict {
        MTSLinkMeetingCheck.verdict(status: status, body: Data(body.utf8))
    }

    private func meeting(_ event: String, made: Bool) -> MTSLinkMeeting {
        MTSLinkMeeting(event: event, owner: "100200300",
                       link: "https://my.mts-link.ru/j/100200300/\(event)",
                       createCall: made ? 1 : nil)
    }

    // MARK: The decision over the event's record

    func testTheQuickMeetingTheLessonMadeIsNotPermanent() {
        let record = #"{"id":20300400500,"name":"Новое мероприятие сегодня","type":"meeting","isEndless":false,"status":"RESERVED","rule":"FREQ=DAILY;COUNT=1","startType":"manual","eventSessions":[]}"#
        XCTAssertEqual(verdict(200, record), .notPermanent)
    }

    func testAQuickMeetingThatRanOnceIsStillNotPermanent() {
        // It worked only while its owner was inside; its session has stopped.
        let record = #"{"id":20300400500,"name":"Новое мероприятие сегодня","type":"meeting","isEndless":false,"status":"STOP","eventSessions":[{"id":20300400600,"status":"STOP"}]}"#
        XCTAssertEqual(verdict(200, record), .notPermanent)
    }

    func testAMeetingThatDoesNotSayItIsEndlessIsNotPermanent() {
        XCTAssertEqual(verdict(200, #"{"id":20300400500,"eventSessions":[{"id":20300400600}]}"#), .notPermanent)
        XCTAssertEqual(verdict(200, #"{"id":20300400500,"isEndless":null,"eventSessions":[{"id":20300400600}]}"#),
                       .notPermanent)
    }

    func testAnEndlessMeetingWithASessionIsUsable() {
        let record = #"{"id":20300400500,"type":"meeting","isEndless":true,"status":"ACTIVE","eventSessions":[{"id":20300400600,"status":"START"}]}"#
        XCTAssertEqual(verdict(200, record), .usable(sessionID: 20300400600))
        XCTAssertTrue(verdict(200, record).isUsable)
        XCTAssertNil(verdict(200, record).refusal)
    }

    func testTheFirstSessionCountsWhateverItsStatusLikeTheCore() {
        let record = #"{"isEndless":true,"eventSessions":[{"id":20300400600,"status":"STOP"},{"id":20300400601,"status":"START"}]}"#
        XCTAssertEqual(verdict(200, record), .usable(sessionID: 20300400600))
    }

    func testAnEndlessMeetingWithoutASessionHasNoSession() {
        for record in [#"{"id":20300400500,"isEndless":true,"eventSessions":[]}"#,
                       #"{"id":20300400500,"isEndless":true}"#,
                       #"{"id":20300400500,"isEndless":true,"eventSessions":[{"id":0}]}"#,
                       #"{"id":20300400500,"isEndless":true,"eventSessions":[{"status":"START"}]}"#,
                       #"{"id":20300400500,"isEndless":true,"eventSessions":[{"id":"20300400600"}]}"#] {
            XCTAssertEqual(verdict(200, record), .noSession, record)
        }
    }

    func testTheStatusesTheCoreReadsAsGoneAreGone() {
        for status in [404, 406, 410] {
            XCTAssertEqual(verdict(status, #"{"error":{"code":406,"message":"Not Acceptable"}}"#), .gone, "\(status)")
            XCTAssertEqual(verdict(status, ""), .gone, "\(status)")
        }
    }

    func testAnythingElseIsUnknown() {
        let endless = #"{"isEndless":true,"eventSessions":[{"id":20300400600}]}"#
        for status in [0, 201, 204, 301, 401, 403, 429, 500, 503] {
            XCTAssertEqual(verdict(status, endless), .unknown, "\(status)")
        }
        for junk in ["", "<html>", "[]", "null", "\"text\"", "{", "20300400600"] {
            XCTAssertEqual(verdict(200, junk), .unknown, junk)
        }
    }

    // MARK: The call is the core's own first call

    func testTheRequestIsTheCoresEventLookup() throws {
        let req = try XCTUnwrap(MTSLinkMeetingCheck.request(event: event))
        XCTAssertEqual(req.url?.absoluteString, "https://gw.mts-link.ru/api/event/20300400500")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Origin"), "https://my.mts-link.ru")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), "https://my.mts-link.ru/")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), MTSLinkRoomService.desktopUserAgent)
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"), "the public record is read without the sign-in")
        XCTAssertFalse(req.httpShouldHandleCookies)
        XCTAssertNil(req.httpBody)
        XCTAssertEqual(req.timeoutInterval, 10)
    }

    func testOnlyAnEventIDBecomesARequest() {
        XCTAssertNil(MTSLinkMeetingCheck.request(event: ""))
        XCTAssertNil(MTSLinkMeetingCheck.request(event: "abc"))
        XCTAssertNil(MTSLinkMeetingCheck.request(event: "1/../2"))
        XCTAssertEqual(MTSLinkMeetingCheck.event(of: link + "?ice=tcp"), event)
        XCTAssertEqual(MTSLinkMeetingCheck.event(of: "  " + link + "/stream-new/20300400600 "), event)
        XCTAssertNil(MTSLinkMeetingCheck.event(of: "https://telemost.yandex.ru/j/12345678901234"))
    }

    // MARK: What the person reads

    func testEveryRefusalIsTheLineForItsKind() {
        XCTAssertEqual(MTSLinkMeetingVerdict.notPermanent.refusal, L10n.mtsMeetingQuick.localized())
        XCTAssertEqual(MTSLinkMeetingVerdict.noSession.refusal, L10n.mtsMeetingNoSession.localized())
        XCTAssertEqual(MTSLinkMeetingVerdict.gone.refusal, L10n.mtsMeetingGone.localized())
        XCTAssertEqual(MTSLinkMeetingVerdict.unknown.refusal, L10n.mtsMeetingUnknown.localized())
        XCTAssertNil(MTSLinkMeetingVerdict.usable(sessionID: 20300400600).refusal)
        for verdict in [MTSLinkMeetingVerdict.notPermanent, .noSession, .gone, .unknown,
                        .usable(sessionID: 20300400600)] {
            XCTAssertFalse(verdict.logText.isEmpty, "\(verdict)")
        }
    }

    func testAnUnusableMeetingIsARoomErrorWithItsLine() {
        let error = MTSLinkRoomError.unusableMeeting(.notPermanent)
        XCTAssertEqual(error.errorDescription, L10n.mtsMeetingQuick.localized())
        XCTAssertFalse(error.needsSignIn, "signing in again makes no meeting permanent")
        XCTAssertFalse(error.logText.isEmpty)
        XCTAssertEqual(MTSLinkRoomError.unusableMeeting(.unknown).errorDescription,
                       L10n.mtsMeetingUnknown.localized())
    }

    // MARK: Pasted links and server paths

    func testOnlyMTSLinkRoomsAreChecked() {
        let options = [InstallOptions(carrier: "jitsi", transport: "datachannel", roomID: "olc-room"),
                       InstallOptions(carrier: "mtslink", transport: "vp8channel", roomID: link + "?ice=tcp"),
                       InstallOptions(carrier: "vkcalls", transport: "datachannel", roomID: "https://vk.com/call/join/x")]
        XCTAssertEqual(MTSLinkMeetingCheck.roomsToCheck(options), [link + "?ice=tcp"])
        XCTAssertEqual(MTSLinkMeetingCheck.roomsToCheck([options[0], options[2]]), [])
    }

    func testTheConnectionEditorChecksOnlyAMeetingNewToTheRecord() {
        let saved = ConnectionRecord(name: "mts", details: .olcrtc(OlcrtcConnection(
            carrier: "mtslink", transport: "vp8channel", roomID: link,
            key: String(repeating: "a", count: 64), clientID: "default")))
        XCTAssertTrue(AddConnectionView.roomIsNew(existing: nil, carrier: "mtslink", roomID: link))
        // The same meeting, hint or not, is no new room.
        XCTAssertFalse(AddConnectionView.roomIsNew(existing: saved, carrier: "mtslink", roomID: link))
        XCTAssertFalse(AddConnectionView.roomIsNew(existing: saved, carrier: "mtslink", roomID: link + "?ice=tcp"))
        XCTAssertTrue(AddConnectionView.roomIsNew(existing: saved, carrier: "mtslink",
                                                  roomID: "https://my.mts-link.ru/j/100200300/20300400501"))
        XCTAssertTrue(AddConnectionView.roomIsNew(existing: saved, carrier: "jitsi", roomID: link))
    }

    // MARK: The lesson's Finish

    func testOneUsableMeetingIsOfferedForConfirmation() {
        let made = meeting("20300400500", made: true)
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(made, .usable(sessionID: 20300400600))], ambiguous: false),
                       .confirm(made))
    }

    func testAQuickMeetingMadeInTheLessonIsRefusedAndTeachesNothing() {
        let made = meeting("20300400500", made: true)
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(made, .notPermanent)], ambiguous: false),
                       .refused(L10n.mtsMeetingQuick.localized()))
    }

    func testAQuickMeetingMadeInTheLessonLeavesOnlyUsableOnesToPick() {
        // A pick never saves a template, so a permanent meeting the page also
        // showed can still be used — but nothing is learned from the quick one.
        let made = meeting("20300400500", made: true)
        let shown = meeting("20300400501", made: false)
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(made, .notPermanent), (shown, .usable(sessionID: 20300400600))],
                                                      ambiguous: true),
                       .pick(L10n.mtsMeetingQuick.localized(), [shown]))
    }

    func testOnlyUsableMeetingsAreOfferedFromSeveral() {
        let a = meeting("20300400500", made: false)
        let b = meeting("20300400501", made: false)
        let c = meeting("20300400502", made: false)
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(a, .usable(sessionID: 1)), (b, .noSession),
                                                       (c, .usable(sessionID: 2))], ambiguous: true),
                       .pick(L10n.mtsLearnSeveral.localized(), [a, c]))
        // An ambiguous lesson stays a pick even when one meeting is left.
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(a, .usable(sessionID: 1)), (b, .gone)], ambiguous: true),
                       .pick(L10n.mtsLearnSeveral.localized(), [a]))
    }

    func testNothingUsableIsRefusedWithTheReasonOfTheMeetingMadeHere() {
        let made = meeting("20300400500", made: true)
        let shown = meeting("20300400501", made: false)
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(shown, .gone), (made, .noSession)], ambiguous: true),
                       .refused(L10n.mtsMeetingNoSession.localized()))
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([(shown, .unknown)], ambiguous: false),
                       .refused(L10n.mtsMeetingUnknown.localized()))
        XCTAssertEqual(MTSLinkMeetingCheck.lessonGate([], ambiguous: false),
                       .refused(L10n.mtsLearnNone.localized()))
    }

    // MARK: The one-button make

    func testAReplayThatMadeTheWrongKindForgetsTheTemplate() {
        XCTAssertEqual(MTSLinkMeetingCheck.replayAction(.usable(sessionID: 20300400600)), .use)
        XCTAssertEqual(MTSLinkMeetingCheck.replayAction(.notPermanent), .dropTemplate)
        XCTAssertEqual(MTSLinkMeetingCheck.replayAction(.noSession), .dropTemplate)
        XCTAssertEqual(MTSLinkMeetingCheck.replayAction(.gone), .dropTemplate)
        // No answer says nothing about the template: keep it, use nothing.
        XCTAssertEqual(MTSLinkMeetingCheck.replayAction(.unknown), .fail)
    }

    func testOnlyANoAnswerIsAskedAgainAfterAMake() {
        // A meeting made a moment ago may not show its session yet.
        XCTAssertTrue(MTSLinkMeetingCheck.worthAskingAgain(.unknown))
        XCTAssertTrue(MTSLinkMeetingCheck.worthAskingAgain(.noSession))
        XCTAssertFalse(MTSLinkMeetingCheck.worthAskingAgain(.notPermanent))
        XCTAssertFalse(MTSLinkMeetingCheck.worthAskingAgain(.gone))
        XCTAssertFalse(MTSLinkMeetingCheck.worthAskingAgain(.usable(sessionID: 20300400600)))
    }

    // MARK: The template saved before the check

    func testTemplatesStoredBeforeTheCheckAreDroppedOnce() throws {
        let suite = "MTSLinkMeetingCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = "olcrtc.mtslink.template.test-\(UUID().uuidString)"
        let account = "template"
        defer {
            defaults.removePersistentDomain(forName: suite)
            MTSLinkTemplateStore.delete(service: service, account: account)
        }
        let template = MTSLinkTemplate(method: "POST", url: "https://my.mts-link.ru/api/events",
                                       contentType: "application/json",
                                       payload: MTSLinkPayload(kind: .json, text: #"{"title":"Room"}"#),
                                       headers: [], eventPath: [.key("data"), .key("id")], linkPath: nil,
                                       owner: "100200300", learnedAt: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(MTSLinkTemplateStore.save(template, service: service, account: account))
        XCTAssertTrue(MTSLinkTemplateStore.dropUncheckedOnce(defaults: defaults, service: service, account: account))
        XCTAssertNil(MTSLinkTemplateStore.load(service: service, account: account))

        // A template learned after the check is kept.
        XCTAssertTrue(MTSLinkTemplateStore.save(template, service: service, account: account))
        XCTAssertFalse(MTSLinkTemplateStore.dropUncheckedOnce(defaults: defaults, service: service, account: account))
        XCTAssertEqual(MTSLinkTemplateStore.load(service: service, account: account), template)
    }

    func testTheOneTimeDropWithNothingStoredOnlySetsTheFlag() throws {
        let suite = "MTSLinkMeetingCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = "olcrtc.mtslink.template.test-\(UUID().uuidString)"
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MTSLinkTemplateStore.dropUncheckedOnce(defaults: defaults, service: service, account: "template"))
        XCTAssertTrue(defaults.bool(forKey: MTSLinkTemplateStore.permanentCheckKey))
    }
}
