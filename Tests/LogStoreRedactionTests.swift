import XCTest
@testable import olcrtc_ios

// Verifies LogStore.redactSecrets scrubs encryption credentials before they
// land in the in-memory buffer or on-disk log file. The provisioning install
// script (`scripts/srv.sh`) prints the 64-hex key + the full olcrtc:// URI
// to its install log; the client tails that log and forwards every line
// into LogStore. Without redaction, the user's Logs tab + any log export
// would contain the encryption credential in plaintext.

@MainActor
final class LogStoreRedactionTests: XCTestCase {

    // MARK: bare 64-hex sequences

    func testBareKeyIsRedacted() {
        let key = String(repeating: "a", count: 64)
        let result = LogStore.redactSecrets("Encryption key: \(key)")
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.contains("<redacted-key>"))
    }

    func testMixedCaseHexIsRedacted() {
        let key = "ABcdEF0123456789" + String(repeating: "f", count: 48)
        XCTAssertEqual(key.count, 64)
        let result = LogStore.redactSecrets(key)
        XCTAssertEqual(result, "<redacted-key>")
    }

    func testMultipleKeysInSameLineAllRedacted() {
        let k1 = String(repeating: "a", count: 64)
        let k2 = String(repeating: "b", count: 64)
        let result = LogStore.redactSecrets("\(k1) and \(k2)")
        XCTAssertFalse(result.contains(k1))
        XCTAssertFalse(result.contains(k2))
        XCTAssertEqual(result, "<redacted-key> and <redacted-key>")
    }

    // MARK: olcrtc:// URI key segment

    func testURIKeyPortionRedactedKeepingPrefix() {
        let key = String(repeating: "c", count: 64)
        let uri = "olcrtc://telemost?vp8channel@room#\(key)%client-id-123$auto"
        let result = LogStore.redactSecrets(uri)
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.hasPrefix("olcrtc://telemost?vp8channel@room#"))
        XCTAssertTrue(result.contains("%client-id-123"), "clientID portion must remain visible for debugging")
        XCTAssertTrue(result.contains("$auto"), "mimo tail must remain visible for debugging")
    }

    func testURIKeyOnlyRedactedWhenNoClientIDOrMimo() {
        let key = String(repeating: "d", count: 64)
        let uri = "olcrtc://carrier?transport@roomID#\(key)"
        let result = LogStore.redactSecrets(uri)
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    // MARK: false-positive guards

    func testShorterHexRunsLeftAlone() {
        // 40-hex (git SHA-length), 32-hex (MD5-length), 63 and 65 — none match.
        let lines = [
            "abc " + String(repeating: "a", count: 40),
            String(repeating: "0", count: 32),
            String(repeating: "f", count: 63),
            String(repeating: "f", count: 65),
        ]
        for line in lines {
            let result = LogStore.redactSecrets(line)
            XCTAssertEqual(result, line, "must not match non-64 hex: \(line)")
        }
    }

    func testBenignTextUnchanged() {
        let line = "✓ SSH connected 1.2.3.4:22 (poll 7, 0/3)"
        XCTAssertEqual(LogStore.redactSecrets(line), line)
    }

    func testRedactionIsIdempotent() {
        let key = String(repeating: "e", count: 64)
        let line = "olcrtc://x?y@z#\(key)%c$m and bare \(key)"
        let once = LogStore.redactSecrets(line)
        let twice = LogStore.redactSecrets(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: integration — actual srv.sh-style banner lines

    func testSrvShBannerLineIsRedacted() {
        // Modelled after scripts/srv.sh lines 237-241 / 268 / 287.
        let key = String(repeating: "9", count: 64)
        let banner = """
        =================== INSTALL DONE ===================
        Encryption key: \(key)
        Container: olcrtc-server-abc123
        URI: olcrtc://telemost?vp8channel@room#\(key)%ios-xyz$auto-provisioned
        ====================================================
        """
        let result = LogStore.redactSecrets(banner)
        XCTAssertFalse(result.contains(key), "the 64-hex key must not survive in any form")
    }

    // MARK: #377 — password-marker scrubbing (defense-in-depth)

    func testRedactsPasswordMarkerValues() {
        XCTAssertEqual(LogStore.redactSecrets("ssh password=hunter2 connecting"),
                       "ssh password=<redacted> connecting")
        XCTAssertEqual(LogStore.redactSecrets("pass: s3cr3t!"), "pass: <redacted>")
        XCTAssertEqual(LogStore.redactSecrets("PASSWD=Xyz"), "PASSWD=<redacted>")
    }

    func testPasswordProseWithoutAValueIsUntouched() {
        // No `=`/`:` value follows, so prose like "(password changed)" is safe.
        let line = "✎ updated VPS: home [root@1.2.3.4:22] (password changed)"
        XCTAssertEqual(LogStore.redactSecrets(line), line)
    }

    // #385: the `\b` word boundary means an interior `pass` is NOT a credential
    // marker — `bypass=`/`compass:`/`surpass=` values must survive verbatim.
    func testInteriorPassSubstringsAreNotRedacted() {
        let lines = [
            "GET /api?bypass=1 -> 200",
            "heading compass: 270deg",
            "surpass=threshold reached",
        ]
        for line in lines {
            XCTAssertEqual(LogStore.redactSecrets(line), line,
                           "interior 'pass' must not trigger redaction: \(line)")
        }
    }

    // #385: a genuine marker preceded by a non-word char (space, `-`, quote, `=`)
    // still redacts — the boundary only blocks word-interior matches.
    func testRealPasswordMarkerStillRedactedAfterBoundaryChars() {
        XCTAssertEqual(LogStore.redactSecrets(#"--password="hunter2""#),
                       #"--password=<redacted>"#)
        XCTAssertEqual(LogStore.redactSecrets("key=val pass=s3cret"),
                       "key=val pass=<redacted>")
    }

    // MARK: #463 — the Yandex session cookie
    //
    // `Session_id` is a bearer credential for the whole Yandex identity (mail,
    // Disk, Pay), usable without the password and past 2FA. Its value matches
    // none of the passes above — not 64-hex, no URI, no "pass"/"token" marker —
    // so it needs its own. Nothing logs it today; this pass is the net for the
    // day something echoes a header.

    func testYandexSessionCookieValueIsRedacted() {
        // Shape-alike fixture, not a real cookie.
        let value = "3:1700000000.5.0.1700000000000:AbCdEf:1a.1.2:1|123456.0.2|0:0.0.0"
        XCTAssertEqual(LogStore.redactSecrets("Cookie: Session_id=\(value)"),
                       "Cookie: Session_id=<redacted>")
        XCTAssertFalse(LogStore.redactSecrets("Session_id=\(value)").contains(value))
    }

    func testYandexSecureTwinIsRedacted() {
        // `sessionid2` is the HTTPS-only twin and just as complete a credential.
        XCTAssertEqual(LogStore.redactSecrets("sessionid2: 3:abcdef"),
                       "sessionid2: <redacted>")
    }

    func testSessionProseWithoutAValueIsUntouched() {
        // The service's own failure line must survive verbatim, and an interior
        // `Session` (SOCKSSession) is not a credential marker.
        for line in ["Telemost: the saved Yandex session was rejected (401)",
                     "SOCKSSession: built a tunnel session"] {
            XCTAssertEqual(LogStore.redactSecrets(line), line)
        }
    }

    // MARK: vless:// links and the OLCOS_* installer facts

    func testVlessUserInfoIsRedacted() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let link = "vless://\(uuid)@203.0.113.9:443?security=reality&pbk=abc#Home"
        let result = LogStore.redactSecrets("import: \(link)")
        XCTAssertFalse(result.contains(uuid))
        XCTAssertTrue(result.hasPrefix("import: vless://<redacted>@203.0.113.9:443"), result)
        XCTAssertEqual(LogStore.redactSecrets(result), result, "idempotent")
    }

    func testXrayURIFactIsRedactedWhole() {
        let line = "OLCOS_XRAY_URI=vless://11111111-2222-3333-4444-555555555555@203.0.113.9:443?security=reality#x"
        XCTAssertEqual(LogStore.redactSecrets(line), "OLCOS_XRAY_URI=<redacted>")
    }

    func testAgentInviteAndIdentityFactsAreRedacted() {
        let cert = "ab12" + String(repeating: "c", count: 60)
        let lines = ["OLCOS_AGENT_INVITE=Q2hhbmdlTWU.p7x",
                     "OLCOS_AGENT_CERT=\(cert)",
                     "OLCOS_AGENT_PREFIX=p7x9",
                     "OLCOS_AGENT_DEVICE=d41d8cd98f00"]
        for line in lines {
            let result = LogStore.redactSecrets(line)
            let marker = String(line.prefix(while: { $0 != "=" })) + "="
            XCTAssertTrue(result.hasPrefix(marker), result)
            XCTAssertFalse(result.contains(String(line.dropFirst(marker.count))), result)
        }
    }

    func testAgentPairingCodeArgumentIsRedacted() {
        let line = "/opt/olcos-agent/olcos-agent revoke-invite -dir /opt/olcos-agent -code 'Q2hhbmdlTWU.p7x' 2>/dev/null"
        let result = LogStore.redactSecrets(line)
        XCTAssertFalse(result.contains("Q2hhbmdlTWU"), result)
        XCTAssertTrue(result.contains("-code '<redacted>'"), result)
        XCTAssertEqual(LogStore.redactSecrets(result), result, "idempotent")
    }

    func testHarmlessAgentFactsStayReadable() {
        for line in ["OLCOS_AGENT_PORT=25113",
                     "OLCOS_AGENT_INVITE_EXPIRES=1700000000",
                     "OLCOS_AGENT_INVITE_ROLE=member",
                     "OLCOS_AGENT_ERROR=no podman"] {
            XCTAssertEqual(LogStore.redactSecrets(line), line)
        }
    }

    // MARK: VK `remixsid` / `access_token` / WB Stream `wb_access_token`
    //
    // The credentials behind the app-created VK calls and WB Stream rooms: the
    // session cookie, the method token the web-token call answers with, and the
    // WB Stream token that is also the account token (`auth.token`). Nothing
    // logs them today — the services put them in request headers and nowhere
    // else — so these passes are the net for the day something echoes a header
    // or a response body.

    func testVKSessionCookieValueIsRedacted() {
        // Shape-alike fixture, not a real cookie.
        let value = "2f0c1a9b8e7d6c5b4a392817.remix-fixture"
        XCTAssertEqual(LogStore.redactSecrets("Cookie: remixsid=\(value)"),
                       "Cookie: remixsid=<redacted>")
        XCTAssertFalse(LogStore.redactSecrets("remixsid=\(value)").contains(value))
    }

    func testQuotedVKSessionCookieIsRedacted() {
        // The quoted value is consumed whole, so the comma or closing brace
        // after it survives (the same shape the quoted-key passes produce).
        XCTAssertEqual(LogStore.redactSecrets(#"{"remixsid":"abc123"}"#),
                       #"{"remixsid":<redacted>}"#)
    }

    func testAccessTokenJSONValueIsRedacted() {
        let body = #"{"data":{"access_token":"token-fixture","user_id":1}}"#
        let result = LogStore.redactSecrets(body)
        XCTAssertFalse(result.contains("token-fixture"), result)
        XCTAssertEqual(result, #"{"data":{"access_token":<redacted>,"user_id":1}}"#)
        XCTAssertEqual(LogStore.redactSecrets(result), result, "idempotent")
    }

    func testWBAccessTokenIsRedactedBothSpellings() {
        let value = "wb.fixture.2f0c1a9b8e7d6c5b"
        // The header it travels in — the same net upstream's own redactor has.
        XCTAssertEqual(LogStore.redactSecrets("Authorization: Bearer \(value)"),
                       "Authorization: Bearer <redacted>")
        XCTAssertFalse(LogStore.redactSecrets("wb_access_token=\(value)").contains(value))
        XCTAssertEqual(LogStore.redactSecrets("wb_access_token=\"v\""),
                       "wb_access_token=<redacted>")
    }

    func testTokenMarkersWithoutAValueStayReadable() {
        for line in ["VK: exchanging the session for an API token (route: direct)",
                     "WB Stream: new room created — 1234567890",
                     "access token kept in Keychain"] {
            XCTAssertEqual(LogStore.redactSecrets(line), line)
        }
    }

    // MARK: `x-auth-token` — the MTS Link cabinet's credential header

    func testXAuthTokenHeaderValueIsRedacted() {
        // Shape-alike fixture, not a real token. The header name stays (it says
        // what the page sent), the value goes; the pass is idempotent.
        let value = "fixture.2f0c1a9b8e7d6c5b4a392817"
        XCTAssertEqual(LogStore.redactSecrets("x-auth-token: \(value)"),
                       "x-auth-token: <redacted>")
        XCTAssertEqual(LogStore.redactSecrets("X-Auth-Token: \(value)"),
                       "X-Auth-Token: <redacted>")
        XCTAssertFalse(LogStore.redactSecrets("x-auth-token: \(value)").contains(value))
        XCTAssertEqual(LogStore.redactSecrets("x-auth-token: <redacted>"),
                       "x-auth-token: <redacted>", "idempotent")
    }

    // MARK: The sign-in capture's scrubbing (MTSLinkRequestCapture)
    //
    // What the MTS Link sign-in sheet keeps is scrubbed BEFORE it is kept: no
    // `Cookie` / `Authorization` / `x-auth-token` value ever reaches the
    // buffer, the copy dump or the learned create request.

    func testCapturedRequestScrubsCredentialHeaders() {
        let request = CapturedRequest.scrubbed(
            method: "post", url: "https://gw.mts-link.ru/api/event",
            headers: ["Cookie": "session=fixture-cookie",
                      "Set-Cookie": "session=fixture-cookie",
                      "Authorization": "Bearer fixture-token",
                      "x-auth-token": "fixture-token",
                      "Content-Type": "application/json"],
            body: #"{"title":"Meeting","access_token":"fixture-token"}"#)
        for name in ["Cookie", "Set-Cookie", "Authorization", "x-auth-token"] {
            XCTAssertEqual(request.headers[name], "<redacted>", name)
        }
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertFalse(request.body.contains("fixture-token"), request.body)
        XCTAssertEqual(request.method, "POST")
    }

    func testCapturedRequestBodyIsCapped() {
        let request = CapturedRequest.scrubbed(
            method: "POST", url: "https://gw.mts-link.ru/api/event",
            headers: [:], body: String(repeating: "a", count: 20_000))
        XCTAssertLessThanOrEqual(request.body.utf8.count, CapturedRequest.maxBodyBytes)
    }
}
