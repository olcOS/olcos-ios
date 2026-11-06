import XCTest
@testable import olcrtc_ios

// VK Calls and SaluteJazz, the two carriers the ghostlane core adds: what the
// room fields accept, how a server's answer and a URI carry them, and what the
// logs hide. The room creation request and the joins themselves are
// integration-only (checked against the real services from a VPS).

@MainActor
final class NewCarriersTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)

    // MARK: VK call links

    func testVKLinksAreTakenFromWhatPeoplePaste() {
        let expected = "https://vk.com/call/join/AbC-d_1"
        XCTAssertEqual(VKCallLink.normalized("https://vk.com/call/join/AbC-d_1"), expected)
        XCTAssertEqual(VKCallLink.normalized("vk.com/call/join/AbC-d_1"), expected)
        XCTAssertEqual(VKCallLink.normalized("https://m.vk.com/call/join/AbC-d_1?utm=x#y"), expected)
        XCTAssertEqual(VKCallLink.normalized("Присоединяйтесь к звонку: https://vk.com/call/join/AbC-d_1 "), expected)
        XCTAssertEqual(VKCallLink.normalized("https://vk.ru/call/join/Z9"), "https://vk.ru/call/join/Z9")
    }

    func testOtherLinksAreNotVKCalls() {
        XCTAssertNil(VKCallLink.normalized(""))
        XCTAssertNil(VKCallLink.normalized("https://vk.com/id1"))
        XCTAssertNil(VKCallLink.normalized("https://vk.com/call/join/"))
        XCTAssertNil(VKCallLink.normalized("https://evil.example/call/join/abc"))
    }

    // MARK: SaluteJazz rooms

    func testSaluteRoomsAreCodeColonPassword() {
        XCTAssertEqual(SaluteJazzRoom.normalized(" Vo0me7:AbcdEfgh "), "vo0me7:abcdefgh")
        XCTAssertNil(SaluteJazzRoom.normalized("vo0me7"))
        XCTAssertNil(SaluteJazzRoom.normalized("vo0me7:"))
        XCTAssertNil(SaluteJazzRoom.normalized("abc:defghij"))       // half too short
        XCTAssertNil(SaluteJazzRoom.normalized("vo0me7:abc:defgh"))   // two colons
        XCTAssertNil(SaluteJazzRoom.normalized("vo0me7:пароль12"))     // not ASCII
    }

    func testTheServiceAnswerBecomesARoomReference() {
        // The real create-meeting answer is pretty-printed, with spaces.
        let answer = Data("""
        {
          "roomId" : "vo0me7",
          "password" : "q1w2e3r4",
          "domain" : "salutejazz.ru",
          "url" : "https://salutejazz.ru/vo0me7?psw=OBdaUQ",
          "isRussianCACertificateRequired" : false
        }
        """.utf8)
        XCTAssertEqual(SaluteJazzRoomService.roomReference(from: answer), "vo0me7:q1w2e3r4")
        XCTAssertNil(SaluteJazzRoomService.roomReference(from: Data("<html>".utf8)))
        XCTAssertNil(SaluteJazzRoomService.roomReference(from: Data(#"{"roomId":"x"}"#.utf8)))
    }

    // MARK: One room rule for every form

    func testRoomInputPerCarrier() {
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "vkcalls", "vk.com/call/join/abc"),
                       "https://vk.com/call/join/abc")
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "salutejazz", "ABCD12:EFGH3456"), "abcd12:efgh3456")
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "telemost", "https://telemost.yandex.ru/j/123"), "123")
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "wbstream", " 12 34 "), "1234")
        XCTAssertTrue(CarrierRoomInput.isValid(carrier: "jitsi", ""))
        XCTAssertFalse(CarrierRoomInput.isValid(carrier: "vkcalls", "not a link"))
        XCTAssertFalse(CarrierRoomInput.isValid(carrier: "salutejazz", "abcd12"))
        XCTAssertFalse(CarrierRoomInput.isValid(carrier: "wbstream", "  "))
    }

    func testWizardRoomsForTheNewCarriers() throws {
        var plan = AddServerCarrierPlan(selected: ["vkcalls", "salutejazz"], transport: [:])
        var rooms = AddServerRoomDraft()
        XCTAssertEqual(rooms.validate(plan: plan), [.missing(carrier: "vkcalls"), .missing(carrier: "salutejazz")])
        rooms.vkLink = "vk.com/call/join"
        rooms.saluteRoom = "abcd12"
        XCTAssertEqual(rooms.validate(plan: plan), [.invalid(carrier: "vkcalls"), .invalid(carrier: "salutejazz")])
        rooms.vkLink = "Звонок: https://vk.com/call/join/xyz"
        rooms.saluteRoom = "abcd12:efgh3456"
        XCTAssertTrue(rooms.validate(plan: plan).isEmpty)

        let options = try XCTUnwrap(plan.installOptions(rooms: rooms))
        XCTAssertEqual(options.primary.carrier, "vkcalls")
        XCTAssertEqual(options.primary.transport, "vp8channel")
        XCTAssertEqual(options.primary.roomID, "https://vk.com/call/join/xyz")
        XCTAssertEqual(options.extras.first?.transport, "datachannel")
        XCTAssertEqual(options.extras.first?.roomID, "abcd12:efgh3456")
        plan.toggle("salutejazz")
        XCTAssertEqual(plan.selected, ["vkcalls"])
    }

    func testRequirementsNameWhatEachCarrierAsks() {
        XCTAssertEqual(AddServerCarrierPlan.requirement(for: "telemost")?.text, .addFlowNeedsYandex)
        XCTAssertEqual(AddServerCarrierPlan.requirement(for: "vkcalls")?.text, .addFlowNeedsVKLink)
        XCTAssertEqual(AddServerCarrierPlan.requirement(for: "salutejazz")?.text, .addFlowNoAccount)
        // WB Stream is not offered, so the wizard asks nothing about it.
        XCTAssertNil(AddServerCarrierPlan.requirement(for: "wbstream"))
        XCTAssertEqual(AddServerCarrierPlan.badge(for: "vkcalls"), .fast)
    }

    // MARK: URIs, tokens, logs, failures

    func testURIsCarryTheNewRoomsUntouched() throws {
        let vk = try OlcrtcURI.parse("olcrtc://vkcalls?vp8channel@https://vk.ru/call/join/AbC-1#\(key)")
        XCTAssertEqual(vk.carrier, "vkcalls")
        XCTAssertEqual(vk.roomID, "https://vk.ru/call/join/AbC-1")
        let salute = try OlcrtcURI.parse("olcrtc://salutejazz?datachannel@abcd12:efgh3456#\(key)")
        XCTAssertEqual(salute.roomID, "abcd12:efgh3456")
        let again = try OlcrtcURI.parse(OlcrtcURI.encode(OlcrtcConnection(from: salute)))
        XCTAssertEqual(again.roomID, "abcd12:efgh3456")
    }

    func testOnlyWBStreamGetsAToken() throws {
        var params = OlcrtcConnection(from: try OlcrtcURI.parse("olcrtc://vkcalls?vp8channel@https://vk.ru/call/join/a#\(key)"))
        params.wbToken = "stray"
        XCTAssertEqual(OlcrtcEngine.providerToken(params), "")
        params.carrier = "wbstream"
        XCTAssertEqual(OlcrtcEngine.providerToken(params), "stray")
    }

    func testSaluteRoomPasswordsStayOutOfLogs() {
        for line in ["supervisor: profile 1 room=abcd12:efgh3456 ready",
                     "OLCRTC_ROOM_ID=abcd12:efgh3456 OLCRTC_CARRIER=salutejazz",
                     #"  id: "abcd12:efgh3456""#,
                     "olcrtc://salutejazz?datachannel@abcd12:efgh3456#00"] {
            let out = LogStore.redactSecrets(line)
            XCTAssertFalse(out.contains("efgh3456"), out)
            XCTAssertTrue(out.contains("abcd12:"), out)
        }
        // Other shapes keep their text.
        XCTAssertEqual(LogStore.redactSecrets("dial localhost:1080 failed"), "dial localhost:1080 failed")
        let jitsi = "room=https://meet.mamba.group/olcos-x"
        XCTAssertEqual(LogStore.redactSecrets(jitsi), jitsi)
    }

    func testVKAndSaluteRoomErrorsReadAsRoomProblems() {
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "vkcalls: room url must be https://vk.ru/call/join/<id>"),
                       .roomInvalid)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "salutejazz: room id is required: malformed room reference"),
                       .roomInvalid)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "vkcalls: auth.getAnonymToken: api error 14 (captcha needed)"),
                       .carrierRejected)
    }
}
