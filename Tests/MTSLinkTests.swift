import XCTest
@testable import olcrtc_ios

// MTS Link, the carrier the ghostlane core's `mtslink` engine joins as a guest
// by a permanent meeting's link: what the room field accepts, how the phone's
// spelling differs from the server's, and how one room is recognized across
// the two. The join itself is integration-only (checked against the real
// service from a VPS).
//
// The olcrtc:// round-trip of a meeting link carrying its ICE hint is pinned
// in OlcrtcURITests (Tests/ServerScriptParityTests.swift).

@MainActor
final class MTSLinkTests: XCTestCase {

    // MARK: The room link

    func testMeetingLinksAreTakenFromWhatPeoplePaste() {
        let expected = "https://my.mts-link.ru/j/100200300/400500600700"
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/100200300/400500600700"), expected)
        XCTAssertEqual(MTSLinkRoom.normalized("my.mts-link.ru/j/100200300/400500600700"), expected)
        XCTAssertEqual(MTSLinkRoom.normalized("http://mts-link.ru/j/100200300/400500600700"), expected)
        XCTAssertEqual(MTSLinkRoom.normalized("Встреча: https://my.mts-link.ru/j/100200300/400500600700 приходите"),
                       expected)
        // The event id is what names the room; a /session/<id> suffix names
        // one occurrence and is dropped, as are other queries and fragments.
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/100200300/400500600700/session/55"),
                       expected)
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/100200300/400500600700?utm=x#frag"),
                       expected)
    }

    func testTheStreamNewPageOfAMeetingIsTheMeeting() {
        let expected = "https://my.mts-link.ru/j/100200300/400500600700"
        let page = "https://my.mts-link.ru/j/100200300/400500600700/stream-new/700800900100"
        XCTAssertEqual(MTSLinkRoom.normalized(page), expected)
        XCTAssertEqual(MTSLinkRoom.normalized(page + "?utm=x#frag"), expected)
        XCTAssertEqual(MTSLinkRoom.normalized("my.mts-link.ru/j/100200300/400500600700/stream-new/7"), expected)
        XCTAssertEqual(MTSLinkRoom.normalized("Ссылка: " + page + " ждём"), expected)
        // The hint survives behind the page, and the alias owner is rewritten.
        XCTAssertEqual(MTSLinkRoom.normalized(page + "?ice=udp"), expected + "?ice=udp")
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/supportwebinar/400500600700/stream-new/7"),
                       "https://my.mts-link.ru/j/0/400500600700")
        XCTAssertEqual(MTSLinkRoom.event(of: page), "400500600700")
        // A 9-digit owner, an 11-digit event and an 11-digit session: the event
        // is the SECOND number after /j/, never the third.
        let shaped = "https://my.mts-link.ru/j/100200300/40050060070/stream-new/70080090010"
        XCTAssertEqual(MTSLinkRoom.normalized(shaped), "https://my.mts-link.ru/j/100200300/40050060070")
        XCTAssertEqual(MTSLinkRoom.event(of: shaped), "40050060070")
        XCTAssertEqual(MTSLinkRoom.owner(of: shaped), "100200300")
        XCTAssertEqual(MTSLinkRoom.normalized(shaped + "/extra/segments?a=1#b"),
                       "https://my.mts-link.ru/j/100200300/40050060070")
        XCTAssertEqual(MTSLinkRoom.plain(page + "?ice=tcp"), expected)
        // The session page and the meeting are one room.
        XCTAssertTrue(RoomIdentity.same(page, expected + "?ice=tcp", carrier: "mtslink"))
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "mtslink", page), expected)
    }

    func testAnAliasOwnerBecomesZeroSoBothEndsSeeOneSpelling() {
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/supportwebinar/400500600700"),
                       "https://my.mts-link.ru/j/0/400500600700")
        // A numeric owner is kept as it stands.
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/42/400500600700"),
                       "https://my.mts-link.ru/j/42/400500600700")
    }

    func testTheICEHintStaysOnThePhone() {
        // A recognized hint survives normalization, in the exact spelling the
        // core's roomhint understands, and nothing else does.
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/1/2?ice=tcp"),
                       "https://my.mts-link.ru/j/1/2?ice=tcp")
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/1/2?utm=x&ice=udp"),
                       "https://my.mts-link.ru/j/1/2?ice=udp")
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/1/2?ice=both"),
                       "https://my.mts-link.ru/j/1/2?ice=both")
        // An unknown mode is not a hint the core knows — the room is plain.
        XCTAssertEqual(MTSLinkRoom.normalized("https://my.mts-link.ru/j/1/2?ice=bogus"),
                       "https://my.mts-link.ru/j/1/2")
        // …and `plain` is the server's spelling of either.
        XCTAssertEqual(MTSLinkRoom.plain("https://my.mts-link.ru/j/1/2?ice=tcp"),
                       "https://my.mts-link.ru/j/1/2")
        XCTAssertEqual(MTSLinkRoom.plain("my.mts-link.ru/j/1/2"), "https://my.mts-link.ru/j/1/2")
    }

    func testOtherLinksAreNotMTSLinkMeetings() {
        XCTAssertNil(MTSLinkRoom.normalized(""))
        XCTAssertNil(MTSLinkRoom.normalized("https://my.mts-link.ru/"))
        XCTAssertNil(MTSLinkRoom.normalized("https://my.mts-link.ru/j/100200300"))          // no event
        XCTAssertNil(MTSLinkRoom.normalized("https://my.mts-link.ru/j/100200300/40x500"))   // event not digits
        XCTAssertNil(MTSLinkRoom.normalized("https://evil.example/j/100200300/400500600700"))
    }

    // MARK: One room, two spellings

    func testARoomWithAndWithoutTheHintIsOneRoom() {
        let plain = "https://my.mts-link.ru/j/100200300/400500600700"
        let hinted = plain + "?ice=tcp"
        XCTAssertTrue(RoomIdentity.same(plain, hinted, carrier: "mtslink"))
        XCTAssertTrue(RoomIdentity.same(hinted, "https://my.mts-link.ru/j/100200300/400500600700?ice=udp",
                                        carrier: "mtslink"))
        // The alias owner's rewrite is one spelling too.
        XCTAssertTrue(RoomIdentity.same("https://my.mts-link.ru/j/supportwebinar/400500600700", plain,
                                        carrier: "mtslink"))
        // Different meetings are different rooms.
        XCTAssertFalse(RoomIdentity.same(plain, "https://my.mts-link.ru/j/100200300/999", carrier: "mtslink"))
        // Other carriers are compared as they stand.
        XCTAssertTrue(RoomIdentity.same("AbC", "AbC", carrier: "vkcalls"))
        XCTAssertFalse(RoomIdentity.same("AbC", "Abc", carrier: "vkcalls"))
    }

    func testThePhoneKeepsItsOwnSpellingOfAConfirmedRoom() {
        let typed = "https://my.mts-link.ru/j/1/2?ice=tcp"
        let confirmed = "https://my.mts-link.ru/j/1/2"
        XCTAssertEqual(RoomIdentity.phoneRoom(carrier: "mtslink", confirmed: confirmed, typed: typed), typed)
        // A server that reports ANOTHER room wins over the phone's old value.
        XCTAssertEqual(RoomIdentity.phoneRoom(carrier: "mtslink", confirmed: "https://my.mts-link.ru/j/1/3",
                                              typed: typed),
                       "https://my.mts-link.ru/j/1/3")
    }

    // MARK: One room rule for every form

    func testRoomInputForMTSLink() {
        XCTAssertEqual(CarrierRoomInput.normalized(carrier: "mtslink",
                                                   "Встреча https://my.mts-link.ru/j/supportwebinar/400500600700?ice=tcp"),
                       "https://my.mts-link.ru/j/0/400500600700?ice=tcp")
        XCTAssertTrue(CarrierRoomInput.isValid(carrier: "mtslink", "my.mts-link.ru/j/1/2"))
        XCTAssertFalse(CarrierRoomInput.isValid(carrier: "mtslink", "not a link"))
        XCTAssertEqual(CarrierRoomInput.placeholder(carrier: "mtslink"), "https://my.mts-link.ru/j/…")
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }
        SettingsStore.shared.language = "en"
        XCTAssertEqual(CarrierRoomInput.hint(carrier: "mtslink"), L10n.roomIDMtslinkHint.localized())
    }

    // MARK: Subscription nodes

    func testASubscriptionNodeIsOneNodeWithOrWithoutTheHint() {
        let key = String(repeating: "ab", count: 32)
        let hinted = "olcrtc://mtslink?vp8channel@https://my.mts-link.ru/j/1/2?ice=tcp#\(key)"
        let plain  = "olcrtc://mtslink?vp8channel@https://my.mts-link.ru/j/1/2#\(key)"
        let a = OlcrtcSubscription.parse(hinted)
        let b = OlcrtcSubscription.parse(plain)
        XCTAssertEqual(a.entries.count, 1)
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(a.entries.first?.nodeKey, b.entries.first?.nodeKey)
    }

    // MARK: The server is told the link with a hint

    func testTheServerRoomIsThePlainLinkPlusAHint() {
        // No hint typed: UDP first, TCP as the fallback.
        XCTAssertEqual(MTSLinkRoom.serverRoom("https://my.mts-link.ru/j/1/2"),
                       "https://my.mts-link.ru/j/1/2?ice=both")
        XCTAssertEqual(MTSLinkRoom.serverRoom("my.mts-link.ru/j/1/2/stream-new/9"),
                       "https://my.mts-link.ru/j/1/2?ice=both")
        XCTAssertEqual(MTSLinkRoom.serverRoom("https://my.mts-link.ru/j/supportwebinar/2"),
                       "https://my.mts-link.ru/j/0/2?ice=both")
        // A typed hint is kept as it is.
        for mode in ["tcp", "udp", "both"] {
            XCTAssertEqual(MTSLinkRoom.serverRoom("https://my.mts-link.ru/j/1/2?ice=\(mode)"),
                           "https://my.mts-link.ru/j/1/2?ice=\(mode)")
        }
        // An unknown mode is no hint.
        XCTAssertEqual(MTSLinkRoom.serverRoom("https://my.mts-link.ru/j/1/2?ice=bogus"),
                       "https://my.mts-link.ru/j/1/2?ice=both")
        XCTAssertNil(MTSLinkRoom.serverRoom("not a link"))
        // The identity does not see the hint at all.
        XCTAssertTrue(RoomIdentity.same(MTSLinkRoom.serverRoom("https://my.mts-link.ru/j/1/2") ?? "",
                                        "https://my.mts-link.ru/j/1/2", carrier: "mtslink"))
    }

    func testTheServerGetsTheLinkWithAHint() {
        let typed = InstallOptions(carrier: "mtslink", transport: "vp8channel",
                                   roomID: "https://my.mts-link.ru/j/1/2?ice=tcp")
        let bare = InstallOptions(carrier: "mtslink", transport: "vp8channel",
                                  roomID: "https://my.mts-link.ru/j/1/2")
        let builders: [(InstallOptions) -> String] = [
            { SSHRunner.installEnv($0) },
            { SSHRunner.addCarrierEnv($0, baseContainer: "olcrtc-server-x") },
        ]
        for build in builders {
            XCTAssertTrue(build(typed).contains("OLCRTC_ROOM_ID=https://my.mts-link.ru/j/1/2?ice=tcp"), build(typed))
            XCTAssertTrue(build(bare).contains("OLCRTC_ROOM_ID=https://my.mts-link.ru/j/1/2?ice=both"), build(bare))
        }
        // Another carrier's room is never touched.
        let vk = InstallOptions(carrier: "vkcalls", transport: "vp8channel",
                                roomID: "https://vk.com/call/join/abc")
        XCTAssertFalse(SSHRunner.installEnv(vk).contains("ice="))
    }

    func testThePhoneDoesNotInheritTheServersDefaultHint() {
        let withDefault = "https://my.mts-link.ru/j/1/2?ice=both"
        // A phone link typed without a hint stays without one.
        XCTAssertEqual(RoomIdentity.phoneRoom(carrier: "mtslink", confirmed: withDefault,
                                              typed: "https://my.mts-link.ru/j/1/2"),
                       "https://my.mts-link.ru/j/1/2")
        // A room that came from the server alone loses its default hint…
        XCTAssertEqual(RoomIdentity.fromServer(carrier: "mtslink", room: withDefault),
                       "https://my.mts-link.ru/j/1/2")
        XCTAssertEqual(RoomIdentity.phoneRoom(carrier: "mtslink", confirmed: "https://my.mts-link.ru/j/1/3?ice=both",
                                              typed: "https://my.mts-link.ru/j/1/2"),
                       "https://my.mts-link.ru/j/1/3")
        // …but keeps a hint somebody chose.
        XCTAssertEqual(RoomIdentity.fromServer(carrier: "mtslink", room: "https://my.mts-link.ru/j/1/2?ice=udp"),
                       "https://my.mts-link.ru/j/1/2?ice=udp")
        // Other carriers are returned as they are.
        XCTAssertEqual(RoomIdentity.fromServer(carrier: "vkcalls", room: "AbC"), "AbC")
    }

    func testTheMTSLinkRoomHintTextNamesTCPAsTheDefault() {
        for locale in AppLocale.allCases {
            let hint = L10n.roomIDMtslinkHint.localized(locale)
            XCTAssertTrue(hint.contains("?ice=udp"), hint)
            XCTAssertTrue(hint.contains("TCP"), hint)
            XCTAssertFalse(hint.contains("?ice=tcp"), hint)
        }
    }

    // MARK: VP8 speed for MTS Link

    func testMTSLinkRunsAtLeastSixtyFramesAndSixtyFourPackets() {
        var tuned = Vp8Tuning.effective(carriers: ["mtslink"], fps: 30, batch: 64)
        XCTAssertEqual(tuned.fps, 60)
        XCTAssertEqual(tuned.batch, 64)
        tuned = Vp8Tuning.effective(carriers: ["mtslink"], fps: 5, batch: 8)
        XCTAssertEqual(tuned.fps, 60)
        XCTAssertEqual(tuned.batch, 64)
        // A bigger batch the person chose is kept.
        tuned = Vp8Tuning.effective(carriers: ["mtslink"], fps: 30, batch: 128)
        XCTAssertEqual(tuned.fps, 60)
        XCTAssertEqual(tuned.batch, 128)
        // One MTS Link lane among others is enough.
        tuned = Vp8Tuning.effective(carriers: ["telemost", "jitsi", "mtslink"], fps: 25, batch: 1)
        XCTAssertEqual(tuned.fps, 60)
        XCTAssertEqual(tuned.batch, 64)
        // Everything else is untouched.
        tuned = Vp8Tuning.effective(carriers: ["telemost", "vkcalls"], fps: 25, batch: 1)
        XCTAssertEqual(tuned.fps, 25)
        XCTAssertEqual(tuned.batch, 1)
        tuned = Vp8Tuning.effective(carriers: [], fps: 30, batch: 64)
        XCTAssertEqual(tuned.fps, 30)
        XCTAssertEqual(tuned.batch, 64)
    }

    func testOnlyTheMTSLinkLaneOfAWholeServerConnectionIsLifted() {
        // Each lane is a runtime of its own: an MTS Link room among others lifts itself, not the VK or Jitsi lane beside it.
        for carrier in ["telemost", "vkcalls", "jitsi", "salutejazz"] {
            let tuned = Vp8Tuning.forLane(carrier: carrier, fps: 25, batch: 8)
            XCTAssertEqual(tuned.fps, 25, carrier)
            XCTAssertEqual(tuned.batch, 8, carrier)
        }
        let mts = Vp8Tuning.forLane(carrier: "mtslink", fps: 25, batch: 8)
        XCTAssertEqual(mts.fps, 60)
        XCTAssertEqual(mts.batch, 64)
    }

    func testEachBondedLaneOfTheVPNConfigCarriesItsOwnNumbers() {
        var connection = OlcrtcConnection(carrier: "vkcalls", transport: "vp8channel", roomID: "room-a",
                                          key: String(repeating: "0", count: 64), clientID: "default")
        connection.bundleLanes = [OlcrtcLane(carrier: "mtslink", transport: "vp8channel", roomID: "room-b")]
        connection.bond = "198.51.100.7:4040"
        let config = VPNConfig(from: connection, dns: "1.1.1.1", timeoutMs: 8_000,
                               fallbackVP8FPS: 30, fallbackVP8Batch: 32, bonded: true)
        XCTAssertEqual(config.lanes.map(\.carrier), ["vkcalls", "mtslink"])
        XCTAssertEqual(config.lanes[0].vp8FPS, 30, "the VK lane keeps the person's numbers")
        XCTAssertEqual(config.lanes[0].vp8Batch, 32)
        XCTAssertEqual(config.lanes[1].vp8FPS, 60, "the MTS Link lane runs at its own")
        XCTAssertEqual(config.lanes[1].vp8Batch, 64)
    }

    func testTheServerConfigOfAnMTSLinkRoomGetsTheTunedNumbers() {
        let settings = SettingsStore.shared
        let savedFPS = settings.vp8FPS, savedBatch = settings.vp8BatchSize
        defer { settings.vp8FPS = savedFPS; settings.vp8BatchSize = savedBatch }
        settings.vp8FPS = 30
        settings.vp8BatchSize = 32
        let mts = InstallOptions(carrier: "mtslink", transport: "vp8channel",
                                 roomID: "https://my.mts-link.ru/j/1/2")
        for env in [SSHRunner.installEnv(mts), SSHRunner.addCarrierEnv(mts, baseContainer: "olcrtc-server-x")] {
            XCTAssertTrue(env.contains("OLCRTC_VP8_FPS=60"), env)
            XCTAssertTrue(env.contains("OLCRTC_VP8_BATCH=64"), env)
        }
        let other = InstallOptions(carrier: "wbstream", transport: "vp8channel", roomID: "room")
        for env in [SSHRunner.installEnv(other), SSHRunner.addCarrierEnv(other, baseContainer: "olcrtc-server-x")] {
            XCTAssertTrue(env.contains("OLCRTC_VP8_FPS=30"), env)
            XCTAssertTrue(env.contains("OLCRTC_VP8_BATCH=32"), env)
        }
    }

    func testReconfigureRewritesOnlyTheVP8BlockOfAnMTSLinkConfig() {
        let mts = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc-mtslink",
            env: ["OLCRTC_CARRIER=mtslink", "OLCRTC_TRANSPORT=vp8channel",
                  "OLCRTC_ROOM_ID=https://my.mts-link.ru/j/1/2?ice=both",
                  "OLCRTC_VP8_FPS=60", "OLCRTC_VP8_BATCH=64"])
        XCTAssertTrue(mts.contains("/^vp8:/,/^[a-z]/{s|^  fps: .*|  fps: 60|;s|^  batch_size: .*|  batch_size: 64|}"), mts)
        XCTAssertTrue(mts.contains(#"id: "https://my.mts-link.ru/j/1/2?ice=both""#), mts)
        let other = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=telemost", "OLCRTC_TRANSPORT=vp8channel",
                  "OLCRTC_ROOM_ID=room1", "OLCRTC_VP8_FPS=30", "OLCRTC_VP8_BATCH=64"])
        XCTAssertFalse(other.contains("/^vp8:/"), other)
    }

    // MARK: Failures read as room problems

    func testMTSLinkRoomErrorsReadAsRoomProblems() {
        XCTAssertEqual(HealthFailureMapper.reason(
            forRaw: "mtslink: room must be the event join link (…/j/{ownerId}/{eventId})"), .roomInvalid)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "mtslink: the service has no such room"), .roomInvalid)
        XCTAssertEqual(HealthFailureMapper.reason(forRaw: "mtslink: the service did not accept the guest"),
                       .carrierRejected)
    }

    // MARK: Reading a create-meeting request's answer

    func testANewMeetingLinkIsFoundInTheAnswer() {
        let old = "https://my.mts-link.ru/j/1/111"
        let answer = "{\"url\":\"https://my.mts-link.ru/j/1/222\",\"title\":\"Weekly\"}"
        XCTAssertEqual(MTSLinkRoom.links(in: answer), ["https://my.mts-link.ru/j/1/222"])
        // A link the request itself carried is not a new meeting.
        let quoted = "{\"from\":\"" + old + "\",\"url\":\"" + old + "\"}"
        XCTAssertEqual(MTSLinkRoom.links(in: quoted), [old])
        // A JSON body spells every slash as `\/`.
        XCTAssertEqual(MTSLinkRoom.links(in: #"{"url":"https:\/\/my.mts-link.ru\/j\/1\/222\/stream-new\/5"}"#),
                       ["https://my.mts-link.ru/j/1/222"])
        // The meeting is named by its event id, hint or not.
        XCTAssertEqual(MTSLinkRoomService.eventId(of: "https://my.mts-link.ru/j/1/222"), "222")
        XCTAssertEqual(MTSLinkRoomService.eventId(of: "https://my.mts-link.ru/j/1/222?ice=tcp"), "222")
    }

    // MARK: The sign-in check's verdict

    func testTheCabinetPageAnswerReadsAsAVerdict() {
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 401, finalURL: "https://my.mts-link.ru/", body: ""),
                       .rejected)
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 403, finalURL: "https://my.mts-link.ru/", body: ""),
                       .rejected)
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 200, finalURL: "https://my.mts-link.ru/cabinet",
                                                  body: "meetings"), .alive)
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 200, finalURL: "https://my.mts-link.ru/login", body: ""),
                       .rejected)
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 200, finalURL: "https://my.mts-link.ru/",
                                                  body: "<input type=\"password\">"), .rejected)
        XCTAssertEqual(MTSLinkRoomService.verdict(status: 500, finalURL: "https://my.mts-link.ru/", body: ""),
                       .unknown)
    }

    func testOnlyASignInIsAResonToAskAgain() {
        XCTAssertTrue(MTSLinkRoomError.noSession.needsSignIn)
        XCTAssertTrue(MTSLinkRoomError.sessionRejected.needsSignIn)
        // Nothing to replay is NOT a sign-in problem: the pasted link is the way.
        XCTAssertFalse(MTSLinkRoomError.noCreateRequest.needsSignIn)
    }

    // MARK: Meetings this app made

    func testOnlyMeetingsThisAppMadeAreRememberedAndCapped() {
        let grown = (1...30).reduce([String]()) { ids, n in
            MTSLinkCreatedRooms.appending("id\(n)", to: ids)
        }
        XCTAssertEqual(grown.count, MTSLinkCreatedRooms.maxRooms)
        XCTAssertEqual(grown.last, "id30")
        XCTAssertFalse(grown.contains("id1"), "the oldest falls off the cap")
    }

    // MARK: What is worth capturing

    func testStaticAssetsAreNotCaptured() {
        XCTAssertFalse(MTSLinkRequestCapture.isInteresting("https://my.mts-link.ru/app.js"))
        XCTAssertFalse(MTSLinkRequestCapture.isInteresting("https://my.mts-link.ru/style.css?v=2"))
        XCTAssertTrue(MTSLinkRequestCapture.isInteresting("https://gw.mts-link.ru/api/events"))
    }
}
