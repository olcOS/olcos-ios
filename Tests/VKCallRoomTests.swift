import XCTest
@testable import olcrtc_ios

// VK Calls one-button room creation.
//
// Everything covered here is PURE: the join-value normalizer
// (`VKCallLink.fromJoinValue`), the response parsers (web_token, calls.start)
// and the error taxonomy on `VKCallRoomService`, and the pure halves of
// `VKSessionStore` (`normalize`, `normalizeStored`, `sessionJar(in:)`,
// `cookieHeader`, `isSessionCookie`, `sessionCookie(in:)`). The
// Keychain round-trip is covered too — it runs against the simulator's own
// keychain and snapshots/restores whatever was there, per the repo convention.
//
// INTEGRATION-ONLY (not covered here, by design):
//   * `VKCallRoomService.createRoom()` — a live authenticated chain against
//     login.vk.ru and api.vk.ru with a real `remixsid`. The parts that CAN be
//     wrong without a network — the URLs, the parsers, the status/error-code
//     mapping — are pinned below.
//   * The route choice, which is `SSHTransport.route` / `.nextRoute` — already
//     covered by `SSHTransportTests`.
//
// SECURITY NOTE: no test here may ever assert on a real session value, and none
// of the fixtures is a real cookie.

// MARK: - VKCallLink.fromJoinValue

final class VKCallJoinValueTests: XCTestCase {

    func testBareIDBecomesTheCanonicalLink() {
        XCTAssertEqual(VKCallLink.fromJoinValue("AbC-d_1"), "https://vk.ru/call/join/AbC-d_1")
    }

    func testFullLinkIsNormalizedLikeAPastedOne() {
        XCTAssertEqual(VKCallLink.fromJoinValue("https://vk.com/call/join/AbC-d_1"),
                       "https://vk.com/call/join/AbC-d_1")
        XCTAssertEqual(VKCallLink.fromJoinValue("https://m.vk.ru/call/join/Z9?utm=x"),
                       "https://vk.ru/call/join/Z9")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(VKCallLink.fromJoinValue("  AbC123 \n"), "https://vk.ru/call/join/AbC123")
    }

    func testForeignAndMalformedValuesAreRefused() {
        // A value the core cannot name must never become a guessed link — it is
        // on its way into server.yaml.
        XCTAssertNil(VKCallLink.fromJoinValue(""))
        XCTAssertNil(VKCallLink.fromJoinValue("   "))
        XCTAssertNil(VKCallLink.fromJoinValue("https://evil.example/call/join/abc"))
        XCTAssertNil(VKCallLink.fromJoinValue("abc def"))
        XCTAssertNil(VKCallLink.fromJoinValue("abc/def"))
        XCTAssertNil(VKCallLink.fromJoinValue("абв"))
    }
}

// MARK: - Response parsers

final class VKCallRoomDecoderTests: XCTestCase {

    func testDecodeAccessTokenReadsTheWebTokenAnswer() throws {
        let data = Data(#"{"data":{"access_token":"token-fixture"}}"#.utf8)
        XCTAssertEqual(try VKCallRoomService.decodeAccessToken(data), "token-fixture")
    }

    func testDecodeAccessTokenRejectsForeignBodies() {
        for body in ["", "{}", #"{"data":{}}"#, #"{"data":{"access_token":""}}"#,
                     "<html>interception</html>"] {
            XCTAssertThrowsError(try VKCallRoomService.decodeAccessToken(Data(body.utf8))) {
                XCTAssertEqual($0 as? VKCallRoomError, .malformedResponse)
            }
        }
    }

    func testWebTokenRefusalIsRecognizedAndMapped() {
        // The exact envelope probed live: HTTP 200, the reason in error_info.
        // "unauthorized" is a missing/stale cookie — the sign-in answer.
        let unauthorized = Data(#"{"type":"error","error_code":"","error_info":"unauthorized"}"#.utf8)
        XCTAssertEqual(VKCallRoomService.webTokenRefusal(in: unauthorized), "unauthorized")
        XCTAssertEqual(VKCallRoomService.error(forWebTokenRefusal: "unauthorized"),
                       VKCallRoomError.sessionRejected)

        // A missing Origin header — our bug, not the user's; still named in
        // the log, still no guessed verdict.
        let wrongOrigin = Data(#"{"type":"error","error_code":"","error_info":"wrong origin"}"#.utf8)
        XCTAssertEqual(VKCallRoomService.webTokenRefusal(in: wrongOrigin), "wrong origin")
        XCTAssertEqual(VKCallRoomService.error(forWebTokenRefusal: "wrong origin"),
                       VKCallRoomError.malformedResponse)

        // Not an envelope: a success body, a method-API error, junk.
        XCTAssertNil(VKCallRoomService.webTokenRefusal(in: Data(#"{"type":"okay","data":{"access_token":"t"}}"#.utf8)))
        XCTAssertNil(VKCallRoomService.webTokenRefusal(in: Data(#"{"error":{"error_code":5}}"#.utf8)))
        XCTAssertNil(VKCallRoomService.webTokenRefusal(in: Data("junk".utf8)))
    }

    func testDecodeCallReadsJoinLinkAsBareID() throws {
        let data = Data(#"{"response":{"call_id":"c1","join_link":"AbC-d_1"}}"#.utf8)
        let room = try VKCallRoomService.decodeCall(data)
        XCTAssertEqual(room, VKCallRoom(link: "https://vk.ru/call/join/AbC-d_1", id: "AbC-d_1"))
    }

    func testDecodeCallReadsJoinLinkAsFullURL() throws {
        let data = Data(#"{"response":{"join_link":"https://vk.com/call/join/Z9"}}"#.utf8)
        let room = try VKCallRoomService.decodeCall(data)
        XCTAssertEqual(room.link, "https://vk.com/call/join/Z9")
        XCTAssertEqual(room.id, "Z9")
    }

    func testDecodeCallFallsBackToOkJoinLink() throws {
        let data = Data(#"{"response":{"call_id":"c1","ok_join_link":"fallbackId"}}"#.utf8)
        let room = try VKCallRoomService.decodeCall(data)
        XCTAssertEqual(room.link, "https://vk.ru/call/join/fallbackId")

        // A blank join_link is no join_link.
        let blank = Data(#"{"response":{"join_link":"","ok_join_link":"fallbackId"}}"#.utf8)
        XCTAssertEqual(try VKCallRoomService.decodeCall(blank).id, "fallbackId")
    }

    func testDecodeCallRejectsForeignBodies() {
        for body in ["{}", #"{"response":{}}"#,
                     #"{"response":{"join_link":"https://evil.example/call/join/x"}}"#,
                     #"{"response":{"join_link":"has spaces"}}"#,
                     "not json"] {
            XCTAssertThrowsError(try VKCallRoomService.decodeCall(Data(body.utf8))) {
                XCTAssertEqual($0 as? VKCallRoomError, .malformedResponse)
            }
        }
    }
}

// MARK: - Error taxonomy

final class VKCallRoomErrorTests: XCTestCase {

    func testErrorCodeIsReadFromTheErrorEnvelope() {
        XCTAssertEqual(VKCallRoomService.errorCode(in: Data(#"{"error":{"error_code":5,"error_msg":"auth"}}"#.utf8)), 5)
        XCTAssertNil(VKCallRoomService.errorCode(in: Data(#"{"response":{"id":1}}"#.utf8)))
        XCTAssertNil(VKCallRoomService.errorCode(in: Data("junk".utf8)))
    }

    func testErrorCodeMapping() {
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 5), .sessionRejected)
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 6), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 9), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 14), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 29), .rateLimited)
        // 15 is "the token did not get attached" — a client bug, NOT a
        // sign-in problem; it must not send the user to re-login.
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 15), .serviceError(status: 15))
        XCTAssertEqual(VKCallRoomService.error(forErrorCode: 42), .serviceError(status: 42))
    }

    func testStatusMapping() {
        XCTAssertEqual(VKCallRoomService.error(forStatus: 401), .sessionRejected)
        XCTAssertEqual(VKCallRoomService.error(forStatus: 403), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forStatus: 429), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forStatus: 503), .rateLimited)
        XCTAssertEqual(VKCallRoomService.error(forStatus: 500), .serviceError(status: 500))
    }

    func testNeedsSignIn() {
        XCTAssertTrue(VKCallRoomError.noSession.needsSignIn)
        XCTAssertTrue(VKCallRoomError.sessionRejected.needsSignIn)
        XCTAssertFalse(VKCallRoomError.rateLimited.needsSignIn)
    }

    func testVerdictOfAWebTokenBody() {
        // A real token: alive.
        XCTAssertEqual(VKCallRoomService.verdict(
            webTokenBody: Data(#"{"type":"okay","data":{"access_token":"t"}}"#.utf8)), .alive)
        // The guest-/no-cookie answer: definitively dead.
        XCTAssertEqual(VKCallRoomService.verdict(
            webTokenBody: Data(#"{"type":"error","error_code":"","error_info":"unauthorized"}"#.utf8)),
            .rejected)
        // Any other refusal is exotic, not a verdict about the session.
        XCTAssertEqual(VKCallRoomService.verdict(
            webTokenBody: Data(#"{"type":"error","error_code":"","error_info":"wrong origin"}"#.utf8)),
            .unknown)
        // An unreadable body is no evidence either way.
        for body in ["", "{}", "junk", "<html>interception</html>"] {
            XCTAssertEqual(VKCallRoomService.verdict(webTokenBody: Data(body.utf8)), .unknown)
        }
    }

    func testErrorMessagesNeverCarrySecrets() {
        // The cases hold no values by construction; the descriptions name only
        // the service and, at most, a status code.
        for error in [VKCallRoomError.noSession, .sessionRejected, .rateLimited,
                      .networkUnavailable, .malformedResponse, .serviceError(status: 500)] {
            XCTAssertFalse((error.errorDescription ?? "").contains("remixsid"))
            XCTAssertFalse((error.errorDescription ?? "").contains("token"))
        }
    }
}

// MARK: - Sign-in check diagnostics
//
// Every web_token check leaves one log line (`signInCheckLine`). The lines are
// what the owner's shared log is read by, so their wording is pinned — and so
// is the rule that nothing secret can reach them.

final class VKSignInCheckLogTests: XCTestCase {

    func testAcceptedAnswerIsNamedWithoutTheToken() {
        let body = Data(#"{"type":"okay","data":{"access_token":"token-fixture","user_id":1}}"#.utf8)
        let line = VKCallRoomService.signInCheckLine(webTokenBody: body)
        XCTAssertEqual(line, "VK sign-in check: accepted")
        XCTAssertFalse(line.contains("token-fixture"))
    }

    func testRefusalNamesVKsReason() {
        let unauthorized = Data(#"{"type":"error","error_code":"","error_info":"unauthorized"}"#.utf8)
        XCTAssertEqual(VKCallRoomService.signInCheckLine(webTokenBody: unauthorized),
                       "VK sign-in check: refused (unauthorized)")
        let wrongOrigin = Data(#"{"type":"error","error_code":"","error_info":"wrong origin"}"#.utf8)
        XCTAssertEqual(VKCallRoomService.signInCheckLine(webTokenBody: wrongOrigin),
                       "VK sign-in check: refused (wrong origin)")
    }

    func testAnUnreadableAnswerIsNoAnswerAndIsNamedBySizeOnly() {
        XCTAssertEqual(VKCallRoomService.signInCheckLine(webTokenBody: Data("<html>".utf8)),
                       "VK sign-in check: no answer (unreadable reply, 6 bytes)")
        XCTAssertEqual(VKCallRoomService.signInCheckLine(webTokenBody: Data()),
                       "VK sign-in check: no answer (unreadable reply, 0 bytes)")
        XCTAssertEqual(VKCallRoomService.signInCheckNoAnswerLine, "VK sign-in check: no answer")
    }

    func testAHostileReasonIsReducedToShortASCII() {
        // JSON escapes: a CR/LF, markup and Cyrillic inside error_info.
        let body = Data(#"{"type":"error","error_code":"","error_info":"bad\r\nreason <b>\u0431\u0443\u043a\u0432\u044b</b>"}"#.utf8)
        let line = VKCallRoomService.signInCheckLine(webTokenBody: body)
        XCTAssertEqual(line, "VK sign-in check: refused (badreason bb)")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("<"))
    }

    func testReasonIsCappedAndNeverEmpty() {
        XCTAssertEqual(VKCallRoomService.diagnosticReason(String(repeating: "a", count: 200)).count, 40)
        XCTAssertEqual(VKCallRoomService.diagnosticReason(""), "unspecified")
        XCTAssertEqual(VKCallRoomService.diagnosticReason("\r\n=;\u{0431}"), "unspecified")
        XCTAssertEqual(VKCallRoomService.diagnosticReason("  wrong_origin.v2-x  "), "wrong_origin.v2-x")
    }
}

// MARK: - VKSessionStore: pure helpers

final class VKSessionNormalizeTests: XCTestCase {

    // Not a real cookie — a shape-alike fixture.
    private let fixture = "2f0c1a9b8e7d6c5b4a392817.remix-fixture"

    func testPlainValuePassesThrough() {
        XCTAssertEqual(VKSessionStore.normalize(fixture), fixture)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(VKSessionStore.normalize("  \(fixture)\n"), fixture)
    }

    func testPastedNameValuePairIsAccepted() {
        XCTAssertEqual(VKSessionStore.normalize("remixsid=\(fixture)"), fixture)
    }

    func testPastedCookieLineKeepsOnlyTheFirstPair() {
        XCTAssertEqual(
            VKSessionStore.normalize("remixsid=\(fixture); remixlang=3; p=1"),
            fixture)
    }

    func testEmptyAndBlankAreRejected() {
        XCTAssertNil(VKSessionStore.normalize(""))
        XCTAssertNil(VKSessionStore.normalize("   \n "))
        XCTAssertNil(VKSessionStore.normalize("remixsid="))
        XCTAssertNil(VKSessionStore.normalize("remixsid=;p=1"))
        // VK's cookie-deletion idiom: a jar can hold a literal DELETED value
        // that passes every syntactic check and signs nothing in.
        XCTAssertNil(VKSessionStore.normalize("DELETED"))
        XCTAssertNil(VKSessionStore.normalize("remixsid=DELETED"))
    }

    func testHeaderInjectionIsRejected() {
        // The value is interpolated into a Cookie header — CR/LF must never pass.
        XCTAssertNil(VKSessionStore.normalize("abc\r\nX-Evil: 1"))
        XCTAssertNil(VKSessionStore.normalize("abc\nX-Evil: 1"))
    }

    func testInteriorWhitespaceAndNonASCIIAreRejected() {
        XCTAssertNil(VKSessionStore.normalize("ab cd"))
        XCTAssertNil(VKSessionStore.normalize("\u{0430}\u{0431}\u{0432}"))   // Cyrillic
    }
}

final class VKSessionCookieTests: XCTestCase {

    private func makeCookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name:   name,
            .value:  value,
            .domain: domain,
            .path:   "/",
        ]))
    }

    func testPicksTheSessionCookieOutOfAJar() throws {
        let jar = [
            try makeCookie(name: "remixlang", value: "3",   domain: ".vk.ru"),
            try makeCookie(name: "remixsid",  value: "abc", domain: ".vk.ru"),
            try makeCookie(name: "p",         value: "2",   domain: ".vk.ru"),
        ]
        XCTAssertEqual(VKSessionStore.sessionCookie(in: jar)?.value, "abc")
    }

    func testSubdomainAndBareDomainCookiesAreAccepted() throws {
        XCTAssertTrue(VKSessionStore.isSessionCookie(
            try makeCookie(name: "remixsid", value: "abc", domain: "login.vk.ru")))
        XCTAssertTrue(VKSessionStore.isSessionCookie(
            try makeCookie(name: "remixsid", value: "abc", domain: "vk.ru")))
    }

    func testLookalikeDomainIsRejected() throws {
        // "evilvk.ru" ends with "vk.ru" but not with ".vk.ru".
        let cookie = try makeCookie(name: "remixsid", value: "abc", domain: "evilvk.ru")
        XCTAssertFalse(VKSessionStore.isSessionCookie(cookie))
        XCTAssertFalse(VKSessionStore.isVKDomain("evilvk.ru"))
        XCTAssertTrue(VKSessionStore.isVKDomain(".vk.ru"))
    }

    func testOtherCookieNamesAreRejected() throws {
        let cookie = try makeCookie(name: "remixsid6", value: "abc", domain: ".vk.ru")
        XCTAssertFalse(VKSessionStore.isSessionCookie(cookie))
        XCTAssertNil(VKSessionStore.sessionCookie(in: [cookie]))
    }

    func testEmptyValuedCookieIsRejected() throws {
        // Foundation may refuse to build a cookie with an empty value at all;
        // when it does build one, the store must still reject it.
        guard let cookie = HTTPCookie(properties: [
            .name: "remixsid", .value: "", .domain: ".vk.ru", .path: "/",
        ]) else {
            throw XCTSkip("Foundation refused an empty cookie value; the store's own guard was not exercised")
        }
        XCTAssertFalse(VKSessionStore.isSessionCookie(cookie))
    }

    func testEmptyJarYieldsNil() {
        XCTAssertNil(VKSessionStore.sessionCookie(in: []))
    }

    func testCookieHeaderIsTheSinglePair() {
        XCTAssertEqual(VKSessionStore.cookieHeader(session: "abc"), "remixsid=abc")
    }
}

// MARK: - VKSessionStore: the cookie jar
//
// The credential is the whole vk.ru jar as one `Cookie`-header string, not the
// `remixsid` alone. Cookie objects are built with Foundation where the test is
// about domains; everything about names, values and header safety is also
// driven through plain strings (`normalizeStored`), because Foundation may
// refuse to build a cookie with a control character in its value.

final class VKSessionJarTests: XCTestCase {

    private func makeCookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name:   name,
            .value:  value,
            .domain: domain,
            .path:   "/",
        ]))
    }

    func testJarCarriesEveryVKCookieWithTheSessionFirst() throws {
        let jar = [
            try makeCookie(name: "remixlang", value: "3",   domain: ".vk.ru"),
            try makeCookie(name: "remixsid",  value: "abc", domain: ".vk.ru"),
            try makeCookie(name: "remixstid", value: "def", domain: "login.vk.ru"),
        ]
        XCTAssertEqual(VKSessionStore.sessionJar(in: jar),
                       "remixsid=abc; remixlang=3; remixstid=def")
    }

    func testOnlyVKDomainsContribute() throws {
        let jar = [
            try makeCookie(name: "remixsid",  value: "abc", domain: ".vk.ru"),
            try makeCookie(name: "tracker",   value: "1",   domain: "evilvk.ru"),
            try makeCookie(name: "elsewhere", value: "2",   domain: "example.com"),
            try makeCookie(name: "suffixed",  value: "3",   domain: "vk.ru.example.com"),
        ]
        XCTAssertEqual(VKSessionStore.sessionJar(in: jar), "remixsid=abc")
    }

    func testLookalikeDomainCannotSupplyTheSession() throws {
        let jar = [try makeCookie(name: "remixsid", value: "abc", domain: "evilvk.ru")]
        XCTAssertNil(VKSessionStore.sessionJar(in: jar))
    }

    func testFirstCookieOfAnyNameWins() throws {
        let jar = [
            try makeCookie(name: "remixsid",  value: "first",  domain: ".vk.ru"),
            try makeCookie(name: "remixsid",  value: "second", domain: "login.vk.ru"),
            try makeCookie(name: "remixlang", value: "3",      domain: ".vk.ru"),
            try makeCookie(name: "remixlang", value: "4",      domain: "id.vk.ru"),
        ]
        XCTAssertEqual(VKSessionStore.sessionJar(in: jar), "remixsid=first; remixlang=3")
    }

    func testDeletedTombstonesAreSkippedAndNeverShadowARealCookie() throws {
        let session   = try makeCookie(name: "remixsid", value: "abc",     domain: ".vk.ru")
        let removed   = try makeCookie(name: "remixir",  value: "DELETED", domain: ".vk.ru")
        let tombstone = try makeCookie(name: "remixsid", value: "DELETED", domain: ".vk.ru")
        XCTAssertEqual(VKSessionStore.sessionJar(in: [removed, session]), "remixsid=abc")
        XCTAssertEqual(VKSessionStore.sessionJar(in: [tombstone, session]), "remixsid=abc")
        XCTAssertNil(VKSessionStore.sessionJar(in: [tombstone]))
    }

    func testEmptyValuedCookieIsSkipped() throws {
        guard let empty = HTTPCookie(properties: [
            .name: "remixlang", .value: "", .domain: ".vk.ru", .path: "/",
        ]) else {
            throw XCTSkip("Foundation refused an empty cookie value; the same rule is covered through normalizeStored")
        }
        let session = try makeCookie(name: "remixsid", value: "abc", domain: ".vk.ru")
        XCTAssertEqual(VKSessionStore.sessionJar(in: [empty, session]), "remixsid=abc")
    }

    func testJarWithoutTheSessionCookieIsRefused() throws {
        let jar = [
            try makeCookie(name: "remixlang", value: "3", domain: ".vk.ru"),
            try makeCookie(name: "remixstid", value: "d", domain: ".vk.ru"),
        ]
        XCTAssertNil(VKSessionStore.sessionJar(in: jar))
        XCTAssertNil(VKSessionStore.sessionJar(in: []))
    }

    func testUnsafeCookiesNeverReachTheJar() throws {
        let session = try makeCookie(name: "remixsid", value: "abc", domain: ".vk.ru")
        guard let injected = HTTPCookie(properties: [
            .name: "evil", .value: "x\r\nX-Injected: 1", .domain: ".vk.ru", .path: "/",
        ]), let poisoned = HTTPCookie(properties: [
            .name: "remixsid", .value: "abc\r\nX-Injected: 1", .domain: ".vk.ru", .path: "/",
        ]) else {
            throw XCTSkip("Foundation refused a control character in a cookie value; the same rule is covered through normalizeStored")
        }
        // A stray unsafe cookie is dropped, never emitted…
        XCTAssertEqual(VKSessionStore.sessionJar(in: [session, injected]), "remixsid=abc")
        // …and a session value that could split the header is no session at all.
        XCTAssertNil(VKSessionStore.sessionJar(in: [poisoned]))
        XCTAssertNil(VKSessionStore.sessionJar(in: [poisoned, injected]))
    }
}

// MARK: - VKSessionStore: what is stored

final class VKSessionStoredValueTests: XCTestCase {

    // Not a real cookie — a shape-alike fixture.
    private let sid = "2f0c1a9b8e7d6c5b4a392817.remix-fixture"

    func testJarStringPassesThroughWithTheSessionFirst() {
        XCTAssertEqual(VKSessionStore.normalizeStored("remixsid=\(sid); remixlang=3; p=1"),
                       "remixsid=\(sid); remixlang=3; p=1")
        // Order and spacing are rebuilt, not trusted.
        XCTAssertEqual(VKSessionStore.normalizeStored("remixlang=3;  remixsid=\(sid) ;p=1"),
                       "remixsid=\(sid); remixlang=3; p=1")
        // A lone pair is a jar of one — the header it makes is the legacy one.
        XCTAssertEqual(VKSessionStore.normalizeStored("remixsid=\(sid)"), "remixsid=\(sid)")
    }

    func testLegacyBareValueStaysBare() {
        XCTAssertEqual(VKSessionStore.normalizeStored(sid), sid)
        XCTAssertEqual(VKSessionStore.normalizeStored("  \(sid)\n"), sid)
        // A bare value may legitimately carry `=` (padding); it is not a jar.
        XCTAssertEqual(VKSessionStore.normalizeStored("abc=="), "abc==")
    }

    func testJarWithoutAUsableSessionIsRefused() {
        XCTAssertNil(VKSessionStore.normalizeStored("remixlang=3; p=1"))
        XCTAssertNil(VKSessionStore.normalizeStored("remixsid=DELETED; remixlang=3"))
        XCTAssertNil(VKSessionStore.normalizeStored("remixsid=; remixlang=3"))
        XCTAssertNil(VKSessionStore.normalizeStored(""))
        XCTAssertNil(VKSessionStore.normalizeStored("   \n "))
    }

    func testEveryPairIsRevalidated() {
        // A name with a space, a quote, a comma and a backslash in values, and
        // a name that is not an RFC 6265 token: each is dropped on its own.
        XCTAssertEqual(
            VKSessionStore.normalizeStored(
                "remixsid=\(sid); bad name=1; ok=2; q=\"x\"; c=a,b; b=a\\b; [x]=1"),
            "remixsid=\(sid); ok=2")
    }

    func testHeaderInjectionIsRefused() {
        XCTAssertNil(VKSessionStore.normalizeStored("remixsid=abc\r\nX-Evil: 1"))
        let cleaned = VKSessionStore.normalizeStored("remixsid=abc; evil=1\r\nX-Evil: 1")
        XCTAssertEqual(cleaned, "remixsid=abc")
        XCTAssertFalse((cleaned ?? "").contains("\r"))
        XCTAssertFalse((cleaned ?? "").contains("\n"))
    }

    func testDuplicatesTombstonesAndEmptiesFollowTheJarRules() {
        XCTAssertEqual(
            VKSessionStore.normalizeStored("remixsid=DELETED; remixsid=\(sid); remixsid=other; a=; a=1"),
            "remixsid=\(sid); a=1")
    }

    func testSignInKeyTracksTheSessionAndWhichCookiesAreThere() {
        let key = VKSessionStore.signInKey(forJar: "remixsid=abc; remixlang=3; remixua=1")
        // The values of the other cookies, and their order, change all the time.
        XCTAssertEqual(key, VKSessionStore.signInKey(forJar: "remixsid=abc; remixua=2; remixlang=9"))
        // Another session is another attempt…
        XCTAssertNotEqual(key, VKSessionStore.signInKey(forJar: "remixsid=abd; remixlang=3; remixua=1"))
        // …and so is a cookie appearing or vanishing around the same session.
        XCTAssertNotEqual(key, VKSessionStore.signInKey(forJar: "remixsid=abc; remixlang=3"))
        XCTAssertNotEqual(key, VKSessionStore.signInKey(forJar: "remixsid=abc; remixlang=3; remixua=1; extra=1"))
    }

    func testCookieCountCountsPairs() {
        XCTAssertEqual(VKSessionStore.cookieCount(inJar: "remixsid=abc; remixlang=3; remixua=1"), 3)
        XCTAssertEqual(VKSessionStore.cookieCount(inJar: "remixsid=abc"), 1)
        XCTAssertEqual(VKSessionStore.cookieCount(inJar: ""), 0)
    }
}

// MARK: - VKSessionStore: the Cookie header

final class VKSessionCookieHeaderTests: XCTestCase {

    func testJarTravelsAsIs() {
        let jar = "remixsid=abc; remixstid=def; remixlang=3"
        XCTAssertEqual(VKSessionStore.cookieHeader(session: jar), jar)
    }

    func testLegacyBareValueBecomesTheSinglePair() {
        XCTAssertEqual(VKSessionStore.cookieHeader(session: "abc"), "remixsid=abc")
        XCTAssertEqual(VKSessionStore.cookieHeader(session: "abc=="), "remixsid=abc==")
    }

    func testAJarIsAlwaysSentInItsCanonicalOrder() {
        XCTAssertEqual(VKSessionStore.cookieHeader(session: "remixlang=3;remixsid=abc"),
                       "remixsid=abc; remixlang=3")
    }

    func testNothingUnsafeEverReachesTheHeader() {
        for raw in ["remixsid=abc\r\nX-Evil: 1", "abc\r\nX-Evil: 1", "abc def", "remixlang=3; p=1"] {
            let header = VKSessionStore.cookieHeader(session: raw)
            XCTAssertEqual(header, "", "\(raw.debugDescription) must not become a header")
        }
        let partly = VKSessionStore.cookieHeader(session: "remixsid=abc; evil=1\r\nX-Evil: 1")
        XCTAssertEqual(partly, "remixsid=abc")
    }
}

// MARK: - Sign-in sheet: when to ask VK again
//
// The sheet's web view, its poll and its status line are integration-only (a
// live WKWebView and VK); the decision of WHEN to ask is pure and pinned here.

final class VKSignInCheckPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func shouldCheck(_ key: String, refused: String?, notBefore: Date?, at moment: Date) -> Bool {
        VKSignInCheckPolicy.shouldCheck(key: key, lastRefusedKey: refused,
                                        notBefore: notBefore, now: moment)
    }

    func testTheFirstJarIsCheckedAtOnce() {
        XCTAssertTrue(shouldCheck("a", refused: nil, notBefore: nil, at: now))
    }

    func testARefusedJarIsNotAskedAgainUntilItChanges() {
        XCTAssertFalse(shouldCheck("a", refused: "a", notBefore: nil, at: now))
        // Even long after the rest is over, an unchanged refused jar stays refused.
        XCTAssertFalse(shouldCheck("a", refused: "a", notBefore: now.addingTimeInterval(-60), at: now))
        XCTAssertTrue(shouldCheck("b", refused: "a", notBefore: nil, at: now))
    }

    func testAChangedJarWaitsOutTheRestAfterTheLastAttempt() {
        let rest = VKSignInCheckPolicy.nextCheck(after: .rejected, now: now)
        XCTAssertEqual(rest, now.addingTimeInterval(3))
        XCTAssertFalse(shouldCheck("b", refused: "a", notBefore: rest, at: now.addingTimeInterval(1)))
        XCTAssertFalse(shouldCheck("b", refused: "a", notBefore: rest, at: now.addingTimeInterval(2.9)))
        XCTAssertTrue(shouldCheck("b", refused: "a", notBefore: rest, at: now.addingTimeInterval(3)))
    }

    func testNoAnswerRetriesTheSameJarAfterALongerRest() {
        let rest = VKSignInCheckPolicy.nextCheck(after: .unknown, now: now)
        XCTAssertEqual(rest, now.addingTimeInterval(10))
        // Nothing was refused, so the same jar is asked about again — later.
        XCTAssertFalse(shouldCheck("a", refused: nil, notBefore: rest, at: now.addingTimeInterval(9)))
        XCTAssertTrue(shouldCheck("a", refused: nil, notBefore: rest, at: now.addingTimeInterval(10)))
    }

    func testAnAcceptedJarNeedsNoFurtherRest() {
        XCTAssertNil(VKSignInCheckPolicy.nextCheck(after: .alive, now: now))
    }
}

// MARK: - VKSessionStore: Keychain round-trip
//
// Touches the ONE real item (`olcrtc.vk.session` / `remixsid`), so setUp
// snapshots it and tearDown puts it back — the repo's rule for tests that share
// real UserDefaults / Keychain state with the app.

@MainActor
final class VKSessionStoreTests: XCTestCase {

    private var snapshot: String?
    private let fixture = "2f0c1a9b8e7d6c5b4a392817.remix-fixture"

    override func setUp() {
        super.setUp()
        snapshot = VKSessionStore.storedSession()
        VKSessionStore().clear()
    }

    override func tearDown() {
        let store = VKSessionStore()
        if let snapshot { store.save(snapshot) } else { store.clear() }
        super.tearDown()
    }

    func testStartsUnlinked() {
        XCTAssertFalse(VKSessionStore().hasSession)
        XCTAssertNil(VKSessionStore.storedSession())
    }

    func testSaveThenLoadRoundTrips() {
        let store = VKSessionStore()
        XCTAssertTrue(store.save(fixture))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
        XCTAssertEqual(VKSessionStore.storedSession(), fixture)
        XCTAssertTrue(VKSessionStore.hasStoredSession())
    }

    func testSaveKeepsAPastedCookieLineAsTheJar() {
        let store = VKSessionStore()
        XCTAssertTrue(store.save("remixlang=3; remixsid=\(fixture)"))
        XCTAssertEqual(store.load(), "remixsid=\(fixture); remixlang=3")
        XCTAssertEqual(VKSessionStore.storedSession(), "remixsid=\(fixture); remixlang=3")
    }

    func testSaveStoresTheJarWholeAndHandsItBack() throws {
        let store = VKSessionStore()
        let jar = "remixsid=\(fixture); remixstid=abc; remixua=1"
        XCTAssertTrue(store.save(jar))
        XCTAssertTrue(store.hasSession)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, jar)
        XCTAssertEqual(VKSessionStore.cookieHeader(session: loaded), jar)
    }

    func testJarWithoutTheSessionIsRejectedWithoutClobbering() {
        let store = VKSessionStore()
        XCTAssertTrue(store.save("remixsid=\(fixture); remixlang=3"))
        XCTAssertFalse(store.save("remixlang=3; remixstid=abc"))
        XCTAssertFalse(store.save("remixsid=DELETED; remixlang=3"))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), "remixsid=\(fixture); remixlang=3")
    }

    func testSaveOverwritesThePreviousSession() {
        let store = VKSessionStore()
        XCTAssertTrue(store.save(fixture))
        XCTAssertTrue(store.save("\(fixture)-second"))
        XCTAssertEqual(store.load(), "\(fixture)-second")
    }

    func testUnusableValueIsRejectedWithoutClobbering() {
        let store = VKSessionStore()
        XCTAssertTrue(store.save(fixture))
        // A bad paste must never silently unlink a working account.
        XCTAssertFalse(store.save("   "))
        XCTAssertFalse(store.save("bad value\r\nX-Evil: 1"))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
    }

    func testClearRemovesTheSession() {
        let store = VKSessionStore()
        store.save(fixture)
        store.clear()
        XCTAssertFalse(store.hasSession)
        XCTAssertNil(VKSessionStore.storedSession())
    }
}
