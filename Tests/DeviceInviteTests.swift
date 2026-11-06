import XCTest
@testable import olcrtc_ios

// Device invites: the link, the encryption, the list the invited device gets,
// the HTTP answer it reads and the server scripts that publish it. The SSH
// round trip and the NWConnection fetch are integration-only.

@MainActor
final class DeviceInviteTests: XCTestCase {

    private let token = "0123456789abcdef0123456789abcdef"
    private let key = Data((0..<32).map { UInt8($0) })

    // MARK: Link

    func testLinkRoundTripsAndItsSourceHasNoKey() throws {
        let link = InviteLink.encode(host: "203.0.113.7", port: 38471, token: token, key: key)
        XCTAssertTrue(link.hasPrefix("olcrtc-sub://203.0.113.7:38471/\(token)?enc=v1#"), link)
        let parsed = try InviteLink.parse(link)
        XCTAssertEqual(parsed.host, "203.0.113.7")
        XCTAssertEqual(parsed.port, 38471)
        XCTAssertEqual(parsed.token, token)
        XCTAssertEqual(parsed.key, key)
        XCTAssertEqual(parsed.source, "olcrtc-sub://203.0.113.7:38471/\(token)?enc=v1")
        XCTAssertFalse(parsed.source.contains("#"))
        XCTAssertTrue(InviteLink.isInvite(link))
        XCTAssertTrue(InviteLink.isInvite(parsed.source))
        XCTAssertEqual(InviteLink.endpoint(of: parsed.source)?.token, token)
    }

    func testIPv6HostIsBracketed() throws {
        let link = InviteLink.encode(host: "2001:db8::7", port: 20000, token: token, key: key)
        XCTAssertTrue(link.hasPrefix("olcrtc-sub://[2001:db8::7]:20000/"), link)
        XCTAssertEqual(try InviteLink.parse(link).host, "2001:db8::7")
    }

    func testOrdinarySubscriptionLinksAreNotInvites() {
        XCTAssertFalse(InviteLink.isInvite("olcrtc-sub://pool.example.org/sub"))
        XCTAssertFalse(InviteLink.isInvite("https://pool.example.org/sub?enc=v1"))
        XCTAssertFalse(InviteLink.isInvite("olcrtc-sub://h:1/\(token)?enc=v2"))
    }

    func testDamagedLinksAreRejected() {
        let good = InviteLink.encode(host: "203.0.113.7", port: 38471, token: token, key: key)
        let noKey = String(good.prefix(while: { $0 != "#" }))
        XCTAssertThrowsError(try InviteLink.parse(noKey)) { XCTAssertEqual($0 as? InviteError, .missingKey) }
        XCTAssertThrowsError(try InviteLink.parse(good.replacingOccurrences(of: token, with: "XYZ"))) {
            XCTAssertEqual($0 as? InviteError, .invalidLink)
        }
        XCTAssertThrowsError(try InviteLink.parse(noKey + "#c2hvcnQ")) { XCTAssertEqual($0 as? InviteError, .missingKey) }
    }

    func testTokensAndKeysAreFresh() {
        let a = InviteLink.makeToken(), b = InviteLink.makeToken()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(InviteLink.isWellFormedToken(a))
        XCTAssertEqual(InviteLink.makeKey().count, 32)
        XCTAssertFalse(InviteLink.isWellFormedToken(a.uppercased()))
    }

    // MARK: Encryption

    func testSealedListOpensOnlyWithItsKey() throws {
        let served = try InviteCipher.seal("#name: ams\n", key: key)
        XCTAssertTrue(served.hasPrefix(InviteCipher.prefix))
        XCTAssertFalse(served.contains("ams"))
        XCTAssertEqual(try InviteCipher.open(served + "\n", key: key), "#name: ams\n")
        XCTAssertThrowsError(try InviteCipher.open(served, key: Data(repeating: 7, count: 32))) {
            XCTAssertEqual($0 as? InviteError, .wrongKey)
        }
        var tampered = Array(served)
        tampered[tampered.count - 5] = tampered[tampered.count - 5] == "A" ? "B" : "A"
        XCTAssertThrowsError(try InviteCipher.open(String(tampered), key: key))
        XCTAssertThrowsError(try InviteCipher.open("<html>captive portal</html>", key: key)) {
            XCTAssertEqual($0 as? InviteError, .notAnInvite)
        }
    }

    // MARK: The list

    private func olcrtcRecord(clientID: String = "default", key: String = String(repeating: "ab", count: 32),
                              name: String = "ams · Telemost") -> ConnectionRecord {
        let uri = "olcrtc://telemost?vp8channel@32559374476312#\(key)" + (clientID == "default" ? "" : "%\(clientID)")
        let parsed = try! OlcrtcURI.parse(uri)
        return ConnectionRecord(name: name, details: .olcrtc(OlcrtcConnection(from: parsed)))
    }

    private func xrayRecord() -> ConnectionRecord {
        let params = try! XrayURI.parse("vless://0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab@203.0.113.7:443"
            + "?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com"
            + "&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0427f68370c8885d&type=tcp").params
        return ConnectionRecord(name: "ams · Xray", details: .xray(params))
    }

    func testListCarriesEveryConnectionUnderItsRecordID() throws {
        let telemost = olcrtcRecord(clientID: "my-phone")
        let xray = xrayRecord()
        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [telemost, xray]))
        XCTAssertTrue(body.hasPrefix("#name: ams\n#refresh: \(InvitePayload.refresh)\n"), body)
        // The admin's own clientID never travels: each device names itself.
        XCTAssertFalse(body.contains("%my-phone"))

        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.xrayEntries.count, 1)
        XCTAssertEqual(sub.entries[0].nodeID, telemost.id.uuidString.lowercased())
        XCTAssertEqual(sub.entries[0].name, "ams · Telemost")
        XCTAssertEqual(sub.entries[0].parsed.clientID, DeviceIdentity.placeholder)
        XCTAssertEqual(sub.xrayEntries[0].nodeID, xray.id.uuidString.lowercased())
        XCTAssertEqual(sub.xrayEntries[0].parsed.params.uuid, "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab")
    }

    func testListCarriesTheAgentOfferWhenTheInviteGivesAccess() throws {
        let offer = AgentOffer(host: "203.0.113.7", port: 25113, certSHA256: "ab12",
                               prefix: "abcdefghijklmnopqrstuv", code: "c0de_c0de", role: "member")
        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [olcrtcRecord()], agent: offer))
        XCTAssertTrue(body.contains("\n#agent: 203.0.113.7:25113\n#agent-cert: ab12\n#agent-prefix: abcdefghijklmnopqrstuv\n"
                                    + "#agent-code: c0de_c0de\n#agent-role: member\n"), body)
        // A reader that knows nothing of the agent still gets the connections.
        XCTAssertEqual(OlcrtcSubscription.parse(body).entries.count, 1)
        XCTAssertFalse(try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [olcrtcRecord()])).contains("#agent"))
        let v6 = AgentOffer(host: "2001:db8::7", port: 1, certSHA256: "", prefix: "", code: "", role: "owner")
        XCTAssertEqual(v6.lines.first, "#agent: [2001:db8::7]:1")
    }

    func testListCarriesTheRoomAge() throws {
        var record = olcrtcRecord()
        if case .olcrtc(var p) = record.details {
            p.roomCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            record.details = .olcrtc(p)
        }
        let body = try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [record]))
        XCTAssertTrue(body.contains("\n##created: 1700000000\n"), body)
        XCTAssertEqual(OlcrtcSubscription.parse(body).entries.count, 1)
        XCTAssertFalse(try XCTUnwrap(InvitePayload.body(serverName: "ams", records: [olcrtcRecord()])).contains("##created"))
    }

    func testAgentInviteOutputParses() throws {
        let ok = try SSHRunner.parseAgentInvite(
            "OLCOS_AGENT_INVITE=abc\nOLCOS_AGENT_INVITE_ROLE=owner\nOLCOS_AGENT_INVITE_EXPIRES=1700000000\n")
        XCTAssertEqual(ok, SSHRunner.AgentInviteResult(code: "abc", role: "owner", expires: 1_700_000_000))
        XCTAssertThrowsError(try SSHRunner.parseAgentInvite("OLCOS_AGENT_ERROR=not_installed\n"))
        XCTAssertThrowsError(try SSHRunner.parseAgentInvite("nothing\n"))
        // shellSafe drops spaces with the rest of the shell's characters.
        XCTAssertTrue(SSHRunner.agentInviteScript(role: "owner", name: "Pixel 9").contains("-role owner -name 'Pixel9' -days 30"))
        XCTAssertTrue(SSHRunner.agentInviteScript(role: "root", name: "").contains("-role member -name 'device'"))
    }

    func testNoListWithoutItsSecrets() {
        var locked = xrayRecord()
        if case .xray(var p) = locked.details { p.uuid = ""; locked.details = .xray(p) }
        XCTAssertNil(InvitePayload.body(serverName: "ams", records: [olcrtcRecord(), locked]))
        XCTAssertNil(InvitePayload.body(serverName: "ams", records: []))
    }

    func testANameCannotStartALineOfItsOwn() throws {
        let record = olcrtcRecord(name: "evil\n##id: other")
        let body = try XCTUnwrap(InvitePayload.body(serverName: "a\n#refresh: 1s", records: [record]))
        XCTAssertFalse(body.contains("\n#refresh: 1s"))
        XCTAssertFalse(body.contains("\n##id: other"))
        XCTAssertEqual(OlcrtcSubscription.parse(body).entries.first?.nodeID, record.id.uuidString.lowercased())
    }

    func testDigestFollowsTheList() {
        XCTAssertEqual(InvitePayload.digest("a"), InvitePayload.digest("a"))
        XCTAssertNotEqual(InvitePayload.digest("a"), InvitePayload.digest("b"))
        XCTAssertEqual(InvitePayload.digest("a").count, 64)
    }

    // MARK: HTTP answer

    private func response(_ head: String, _ body: String) -> Data {
        Data((head + "\r\n\r\n" + body).utf8)
    }

    func testOKAnswerYieldsTheBody() throws {
        let data = response("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close", "hello")
        XCTAssertEqual(try InviteFetcher.body(ofResponse: data), Data("hello".utf8))
        let noLength = response("HTTP/1.0 200 OK", "abc")
        XCTAssertEqual(try InviteFetcher.body(ofResponse: noLength), Data("abc".utf8))
    }

    func testMissingListMeansRevoked() {
        XCTAssertThrowsError(try InviteFetcher.body(ofResponse: response("HTTP/1.1 404 Not Found", ""))) {
            XCTAssertEqual($0 as? InviteError, .revoked)
        }
    }

    func testOtherAnswersAreErrors() {
        XCTAssertThrowsError(try InviteFetcher.body(ofResponse: response("HTTP/1.1 500 Oops", ""))) {
            XCTAssertEqual($0 as? InviteFetcher.FetchError, .httpStatus(500))
        }
        XCTAssertThrowsError(try InviteFetcher.body(ofResponse:
            response("HTTP/1.1 200 OK\r\nContent-Length: 50", "short"))) {
            XCTAssertEqual($0 as? InviteFetcher.FetchError, .malformedResponse)
        }
        XCTAssertThrowsError(try InviteFetcher.body(ofResponse:
            response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked", "5\r\nhello\r\n0\r\n\r\n")))
        XCTAssertThrowsError(try InviteFetcher.body(ofResponse: Data("garbage".utf8)))
    }

    // MARK: Server scripts

    func testPublishScriptStartsTheServerAndWritesEachList() {
        let script = SSHRunner.sharePublishScript(port: 38471, lists: [
            (token: token, served: "olcos1:QUJD+/=="),
            (token: "not-a-token", served: "olcos1:QUJD"),
            (token: "ffffffffffffffffffffffffffffffff", served: "olcos1:'; rm -rf / #"),
        ])
        XCTAssertTrue(script.contains("podman run -d --name olcos-share --restart=always -p 38471:8080"))
        XCTAssertTrue(script.contains(AppConstants.shareServerImage))
        XCTAssertTrue(script.contains("httpd -f -p 8080 -h /www"))
        XCTAssertTrue(script.contains("-v \"$D:/www:ro,Z\""))
        XCTAssertTrue(script.contains("printf '%s' 'olcos1:QUJD+/==' > \"$D/.tmp-\(token)\""))
        XCTAssertTrue(script.contains("mv -f \"$D/.tmp-\(token)\" \"$D/\(token)\""))
        XCTAssertTrue(script.contains("echo OLCOS_SHARE_OK=\(token)"))
        // A malformed token or anything outside the cipher alphabet never reaches the shell.
        XCTAssertFalse(script.contains("not-a-token"))
        XCTAssertFalse(script.contains("rm -rf /"))
        XCTAssertFalse(script.contains("ffffffffffffffffffffffffffffffff"))
    }

    func testDeleteScriptRemovesTheServerWithItsLastList() {
        let script = SSHRunner.shareDeleteScript(tokens: [token, "../etc/passwd"])
        XCTAssertTrue(script.contains("rm -f \"$D/\(token)\" && echo OLCOS_SHARE_DELETED=\(token)"))
        XCTAssertFalse(script.contains("passwd"))
        XCTAssertTrue(script.contains("podman rm -f olcos-share"))
        XCTAssertTrue(script.contains("! -name index.html"))
    }

    func testDeepUninstallTakesTheShareServer() {
        let script = SSHRunner.deepUninstallScript(containerName: "olcrtc-server-abc", removeImage: false)
        XCTAssertTrue(script.contains("podman rm -f olcos-share"))
        XCTAssertTrue(script.contains("rm -rf /opt/olcos-share"))
    }

    func testShareOutputIsParsed() {
        let result = SSHRunner.parseShareOutput("""
        OLCOS_SHARE_PORT=38471
        OLCOS_SHARE_OK=\(token)
        noise
        OLCOS_SHARE_DELETED=ffffffffffffffffffffffffffffffff
        OLCOS_SHARE_STOPPED=1
        """)
        XCTAssertEqual(result.port, 38471)
        XCTAssertEqual(result.written, [token])
        XCTAssertEqual(result.deleted, ["ffffffffffffffffffffffffffffffff"])
        XCTAssertTrue(result.stopped)
        XCTAssertNil(result.error)
        XCTAssertEqual(SSHRunner.parseShareOutput("OLCOS_SHARE_ERROR=port_busy").error, "port_busy")
    }

    // MARK: Host model

    func testLinkedConnectionsComeInCardOrderOnce() {
        let a = UUID(), b = UUID(), x = UUID()
        var host = ServerHost(label: "ams", host: "203.0.113.7")
        host.lastConnectionID = a
        host.extraConnectionIDs = [b, a]
        host.xrayConnectionID = x
        XCTAssertEqual(host.linkedConnectionIDs, [a, b, x])
    }

    func testHostsSavedBeforeInvitesStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"ams","host":"203.0.113.7","port":22,"username":"root"}"#
        let host = try JSONDecoder().decode(ServerHost.self, from: Data(old.utf8))
        XCTAssertNil(host.invites)
        XCTAssertNil(host.sharePort)
        var withInvite = host
        withInvite.invites = [DeviceInvite(name: "iPad", token: token)]
        withInvite.sharePort = 38471
        let again = try JSONDecoder().decode(ServerHost.self, from: JSONEncoder().encode(withInvite))
        XCTAssertEqual(again.invites?.first?.token, token)
        XCTAssertEqual(again.sharePort, 38471)
    }
}
