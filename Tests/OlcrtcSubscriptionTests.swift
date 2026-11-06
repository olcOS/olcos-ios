import XCTest
@testable import olcrtc_ios

// #111: subscription links. Pins the two halves of the import pipeline:
//  - the olcrtc-sub:// → https:// link mapping (an olcrtc-ios convention,
//    documented in docs/uri.md), and
//  - the sub.md payload parser (upstream spec: olcrtc-upstream/docs/sub.md —
//    `#key:` global fields, `olcrtc://` lines, `##key:` per-server fields
//    bound to the nearest preceding URI).

final class OlcrtcSubscriptionTests: XCTestCase {

    // MARK: Server access carried by a device invite (`#agent*`)

    func testAgentOfferIsReadFromTheGlobalFields() {
        let body = """
        #name: Home
        #agent: 203.0.113.5:25113
        #agent-cert: \(String(repeating: "ab", count: 32))
        #agent-prefix: p7x
        #agent-code: Q2hhbmdlTWU
        #agent-role: owner
        olcrtc://wbstream?datachannel@room#aa
        """
        let sub = OlcrtcSubscription.parse(body)
        let offer = sub.agent
        XCTAssertEqual(offer?.host, "203.0.113.5")
        XCTAssertEqual(offer?.port, 25113)
        XCTAssertEqual(offer?.prefix, "p7x")
        XCTAssertEqual(offer?.code, "Q2hhbmdlTWU")
        XCTAssertEqual(offer?.role, "owner")
        XCTAssertEqual(sub.entries.count, 1)
    }

    func testAgentOfferNeedsEveryPartAndReadsIPv6() {
        XCTAssertNil(OlcrtcSubscription.parse("#agent: 203.0.113.5:25113\n").agent)
        let fields = ["agent": "[2001:db8::1]:443", "agent-cert": String(repeating: "0", count: 64),
                      "agent-prefix": "x", "agent-code": "c"]
        let offer = AgentOffer(fields: fields)
        XCTAssertEqual(offer?.host, "2001:db8::1")
        XCTAssertEqual(offer?.port, 443)
        XCTAssertEqual(offer?.role, "member")   // absent or unknown reads as the smaller role
        XCTAssertNil(AgentOffer(fields: ["agent": "h:0", "agent-cert": String(repeating: "0", count: 64),
                                         "agent-prefix": "x", "agent-code": "c"]))
    }

    @MainActor
    func testAgentOnlyHostAnswersTheAgentSecret() {
        var host = ServerHost(label: "Home", host: "203.0.113.5")
        host.agentOnly = true
        XCTAssertEqual(ServerHostStore(defaults: UserDefaults(suiteName: "olcos.tests.agentonly")!).secret(for: host), .agent)
        XCTAssertFalse(host.canManage)
        host.agentRole = "owner"
        XCTAssertTrue(host.canManage)
    }

    // MARK: olcrtc-sub:// → https:// mapping

    func testHTTPSMappingSwapsOnlyTheScheme() throws {
        let url = URL(string: "olcrtc-sub://pool.example.org/sub")!
        XCTAssertEqual(try OlcrtcSubscription.httpsURL(from: url).absoluteString,
                       "https://pool.example.org/sub")
    }

    func testHTTPSMappingPreservesPortPathAndQuery() throws {
        let url = URL(string: "olcrtc-sub://pool.example.org:8443/a/b/sub?token=xyz")!
        XCTAssertEqual(try OlcrtcSubscription.httpsURL(from: url).absoluteString,
                       "https://pool.example.org:8443/a/b/sub?token=xyz")
    }

    func testHTTPSMappingRejectsForeignScheme() {
        // A plain olcrtc:// connection URI is not a subscription link.
        let url = URL(string: "olcrtc://wbstream?datachannel@room#aa")!
        XCTAssertThrowsError(try OlcrtcSubscription.httpsURL(from: url))
    }

    func testHTTPSMappingRejectsMissingHost() {
        let url = URL(string: "olcrtc-sub:///sub")!
        XCTAssertThrowsError(try OlcrtcSubscription.httpsURL(from: url))
    }

    // MARK: sub.md payload parsing

    /// The full example from olcrtc-upstream/docs/sub.md, verbatim.
    private let upstreamExample = """
    #name: Zarazaex Free RU
    #update: 1778011200
    #refresh: 10m
    #color: #4A90E2
    #icon: 🇷🇺
    #used: 10mb/10gb
    #available: 9.99gb

    olcrtc://wbstream?seichannel<fps=60&batch=64&frag=900&ack-ms=2000>@room-01#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$RU / olcng free sub / IPv6
    ##name: RU-1
    ##icon: 🇷🇺
    ##color: #4A90E2
    ##used: 500mb/10gb
    ##available: 9.5gb
    ##ip: 203.0.113.10
    ##comment: basic free node

    olcrtc://wbstream?datachannel@abc123xyz#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$DE / backup / IPv4
    ##name: DE-Backup
    ##icon: 🇩🇪
    ##color: #2EBD85
    ##comment: reserve route, wbstream+datachannel does not work in guest flow
    """

    func testReadsTheHeaderOtherClientsListsCarry() {
        let body = """
        # profile-title: WHITE LISTS | Mobile
        # profile-update-interval: 1
        # Date/Time: 2026-10-10 / 00:51 (Moscow)
        vless://adc11f30-e4cb-4985-bf5e-f9ded69c019f@90.156.218.163:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=eh.vk.ru&pbk=fNfokzklCF4l_c8k8PciOCjm5ecNoF_sNLjEtaO-xzI&sid=db04ce8bdb8900f1&type=raw&fp=chrome#PL
        vless://2f9107cb-9af0-4c94-a89d-50437218e5fa@ap2.directly.chat:443?encryption=none&security=tls&sni=ap2.directly.chat&type=ws#MD
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.name, "WHITE LISTS | Mobile")
        XCTAssertEqual(sub.refreshInterval, 3600)
        XCTAssertEqual(sub.xrayEntries.count, 1, "the raw transport is TCP; TLS over WebSocket is not supported")
        XCTAssertEqual(sub.skippedURIs, 1)
    }

    func testOwnHeaderFieldsWinOverTheOtherClientsOnes() {
        let sub = OlcrtcSubscription.parse("#name: Mine\n#refresh: 6h\n# profile-title: Theirs\n# profile-update-interval: 1")
        XCTAssertEqual(sub.name, "Mine")
        XCTAssertEqual(sub.refreshInterval, 6 * 3600)
    }

    func testReadsABase64EncodedList() throws {
        let links = "vless://adc11f30-e4cb-4985-bf5e-f9ded69c019f@90.156.218.163:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=eh.vk.ru&pbk=fNfokzklCF4l_c8k8PciOCjm5ecNoF_sNLjEtaO-xzI&sid=db04ce8bdb8900f1&type=tcp#PL\n"
        let encoded = Data(links.utf8).base64EncodedString()
        XCTAssertEqual(OlcrtcSubscription.parse(encoded).xrayEntries.count, 1)
        guard case .subscriptionBody = OlcrtcSubscription.detectImport(encoded) else {
            return XCTFail("a pasted base64 list is a subscription body")
        }
        XCTAssertNil(OlcrtcSubscription.decodedBase64Body("hello world, nothing to see here"))
        XCTAssertNil(OlcrtcSubscription.decodedBase64Body(Data("plain text without links".utf8).base64EncodedString()))
    }

    func testParsesUpstreamExample() {
        let sub = OlcrtcSubscription.parse(upstreamExample)

        XCTAssertEqual(sub.name, "Zarazaex Free RU")
        XCTAssertEqual(sub.entries.count, 2)
        XCTAssertEqual(sub.skippedURIs, 0)

        let first = sub.entries[0]
        XCTAssertEqual(first.name, "RU-1")
        XCTAssertEqual(first.parsed.carrier, "wbstream")
        XCTAssertEqual(first.parsed.transport, "seichannel")
        XCTAssertEqual(first.parsed.roomID, "room-01")
        XCTAssertEqual(first.parsed.key,
            "d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799")
        XCTAssertEqual(first.parsed.mimo, "RU / olcng free sub / IPv6")

        let second = sub.entries[1]
        XCTAssertEqual(second.name, "DE-Backup")
        XCTAssertEqual(second.parsed.transport, "datachannel")
        XCTAssertEqual(second.parsed.roomID, "abc123xyz")
    }

    func testLocalFieldsBindToNearestPrecedingURI() {
        let body = """
        ##name: orphan — no URI above, must be dropped
        olcrtc://wbstream?datachannel@r1#aa
        ##name: first
        olcrtc://wbstream?datachannel@r2#bb
        ##name: second
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 2)
        XCTAssertEqual(sub.entries[0].name, "first")
        XCTAssertEqual(sub.entries[1].name, "second")
    }

    func testUnparseableURILineIsCountedNotFatal() {
        let body = """
        olcrtc://broken-no-transport
        olcrtc://wbstream?datachannel@room#cc
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.skippedURIs, 1)
        XCTAssertEqual(sub.entries[0].parsed.roomID, "room")
    }

    func testTolerantOfStrayTextAndUnknownFields() {
        let body = """
        some stray banner text
        #refresh: 10m
        #malformed-no-colon
        olcrtc://wbstream?datachannel@room#dd
        ##unknown: ignored
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertNil(sub.name)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.skippedURIs, 0)
    }

    func testEmptyAndMetadataOnlyBodiesYieldNoEntries() {
        XCTAssertTrue(OlcrtcSubscription.parse("").entries.isEmpty)
        XCTAssertTrue(OlcrtcSubscription.parse("#name: Empty pool\n\n").entries.isEmpty)
    }

    // MARK: record-name fallback chain (##name → $mimo → carrier · transport)

    func testRecordNamePrefersLocalNameThenMimoThenFallback() {
        let body = """
        olcrtc://wbstream?datachannel@r1#aa$Mimo Label
        ##name: Explicit
        olcrtc://wbstream?datachannel@r2#bb$Mimo Only
        olcrtc://wbstream?datachannel@r3#cc
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 3)
        XCTAssertEqual(sub.entries[0].recordName, "Explicit")
        XCTAssertEqual(sub.entries[1].recordName, "Mimo Only")
        XCTAssertEqual(sub.entries[2].recordName, "wbstream · datachannel")
    }

    // MARK: #363 — carried-through metadata (previously parsed-then-dropped)

    func testGlobalAndNodeMetadataAreCarried() {
        let sub = OlcrtcSubscription.parse(upstreamExample)
        // Global #used / #available now retained.
        XCTAssertEqual(sub.used, "10mb/10gb")
        XCTAssertEqual(sub.available, "9.99gb")
        // Per-node ##used / ##available / ##ip / ##comment retained on the entry.
        let first = sub.entries[0]
        XCTAssertEqual(first.used, "500mb/10gb")
        XCTAssertEqual(first.available, "9.5gb")
        XCTAssertEqual(first.ip, "203.0.113.10")
        XCTAssertEqual(first.comment, "basic free node")
        // The second node has only a comment (no ip/used/available).
        let second = sub.entries[1]
        XCTAssertNil(second.ip)
        XCTAssertEqual(second.comment,
            "reserve route, wbstream+datachannel does not work in guest flow")
    }

    func testNodeMetadataBindsToNearestPrecedingURI() {
        let body = """
        olcrtc://wbstream?datachannel@r1#aa
        ##ip: 10.0.0.1
        ##comment: node one
        olcrtc://wbstream?datachannel@r2#bb
        ##comment: node two
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries[0].ip, "10.0.0.1")
        XCTAssertEqual(sub.entries[0].comment, "node one")
        XCTAssertNil(sub.entries[1].ip)
        XCTAssertEqual(sub.entries[1].comment, "node two")
    }

    // MARK: #361 — paste-and-import detection (pure classifier)

    func testDetectSingleConnectionURI() {
        let input = "olcrtc://wbstream?datachannel@room#aa"
        XCTAssertEqual(OlcrtcSubscription.detectImport(input), .connectionURI(input))
        // Leading/trailing whitespace is trimmed.
        XCTAssertEqual(OlcrtcSubscription.detectImport("  \(input)\n"), .connectionURI(input))
    }

    func testDetectSubscriptionLink() {
        let sub = "olcrtc-sub://pool.example.org/sub"
        XCTAssertEqual(OlcrtcSubscription.detectImport(sub),
                       .subscriptionURL(URL(string: sub)!))
        let https = "https://pool.example.org/sub"
        XCTAssertEqual(OlcrtcSubscription.detectImport(https),
                       .subscriptionURL(URL(string: https)!))
    }

    func testDetectHTTPSOnlyForURLs() {
        // A plain http:// link is NOT treated as a subscription URL (ATS posture).
        XCTAssertEqual(OlcrtcSubscription.detectImport("http://pool.example.org/sub"),
                       .unrecognized)
    }

    func testDetectRawSubscriptionBody() {
        let body = """
        #name: Pool
        olcrtc://wbstream?datachannel@r1#aa
        ##name: A
        olcrtc://wbstream?datachannel@r2#bb
        """
        guard case .subscriptionBody = OlcrtcSubscription.detectImport(body) else {
            return XCTFail("multi-line sub.md text must detect as a body")
        }
        // A metadata-only multi-line blob with a marker still routes as a body
        // (parse decides it's empty downstream).
        guard case .subscriptionBody = OlcrtcSubscription.detectImport("#name: x\nsome banner") else {
            return XCTFail("a #marker line marks the blob as a sub body")
        }
    }

    func testDetectUnrecognized() {
        XCTAssertEqual(OlcrtcSubscription.detectImport(""), .unrecognized)
        XCTAssertEqual(OlcrtcSubscription.detectImport("just some random text"), .unrecognized)
        // Multiple olcrtc:// lines (no markers) still detect as a body, not a single URI.
        guard case .subscriptionBody = OlcrtcSubscription.detectImport(
            "olcrtc://wbstream?datachannel@r1#aa\nolcrtc://wbstream?datachannel@r2#bb") else {
            return XCTFail("multiple connection URIs detect as a body")
        }
    }

    func testLinkWithWordsAroundItIsExtracted() {
        let link = "olcrtc://wbstream?datachannel@room#aa"
        XCTAssertEqual(OlcrtcSubscription.detectImport("Here you go: \(link), enjoy!"), .connectionURI(link))
        XCTAssertEqual(OlcrtcSubscription.detectImport("the list → https://example.com/sub.md."),
                       .subscriptionURL(URL(string: "https://example.com/sub.md")!))
        XCTAssertEqual(OlcrtcSubscription.detectImport("nothing to see here"), .unrecognized)
        XCTAssertEqual(OlcrtcSubscription.firstLink(in: "(vless://u@h:443?x=1#n)"), "vless://u@h:443?x=1#n")
    }
}
