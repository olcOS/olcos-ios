import XCTest
@testable import olcrtc_ios

/// The `vless://` codec and the xray wiring of `VPNConfig`. The canonical link
/// shape is the one olcos-core emits (`profile.export`), so a link produced by
/// the server installer must round-trip here unchanged in meaning.
final class XrayConnectionTests: XCTestCase {

    private let canonical = "vless://0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab@203.0.113.7:443"
        + "?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com"
        + "&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0427f68370c8885d"
        + "&spx=%2F&type=tcp#olcos%20vps"

    func testParseCanonicalLink() throws {
        let parsed = try XrayURI.parse(canonical)
        let p = parsed.params
        XCTAssertEqual(p.host, "203.0.113.7")
        XCTAssertEqual(p.port, 443)
        XCTAssertEqual(p.uuid, "0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab")
        XCTAssertEqual(p.sni, "www.example.com")
        XCTAssertEqual(p.publicKey, "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc")
        XCTAssertEqual(p.shortID, "0427f68370c8885d")
        XCTAssertEqual(p.fingerprint, "chrome")
        XCTAssertEqual(p.flow, "xtls-rprx-vision")
        XCTAssertEqual(p.spiderX, "/")
        XCTAssertEqual(parsed.name, "olcos vps")
    }

    func testEncodeParseRoundTrip() throws {
        let parsed = try XrayURI.parse(canonical)
        let again = try XrayURI.parse(XrayURI.encode(parsed.params, name: parsed.name))
        XCTAssertEqual(again, parsed)
    }

    func testEncodeEmitsCanonicalQuery() throws {
        let p = try XrayURI.parse(canonical).params
        let out = XrayURI.encode(p, name: "olcos vps")
        XCTAssertTrue(out.hasPrefix("vless://0f6a4b3e-2a9c-4f1e-9e8f-0123456789ab@203.0.113.7:443?"), out)
        for needle in ["encryption=none", "flow=xtls-rprx-vision", "security=reality",
                       "sni=www.example.com", "fp=chrome", "sid=0427f68370c8885d",
                       "spx=%2F", "type=tcp"] {
            XCTAssertTrue(out.contains(needle), "\(needle) missing in \(out)")
        }
        XCTAssertTrue(out.hasSuffix("#olcos%20vps"), out)
    }

    func testDefaultsWhenOptionalKeysAbsent() throws {
        let p = try XrayURI.parse("vless://u@h:8443?security=reality&sni=s&pbk=k").params
        XCTAssertEqual(p.port, 8443)
        XCTAssertEqual(p.fingerprint, "chrome")
        XCTAssertEqual(p.spiderX, "/")
        XCTAssertEqual(p.shortID, "")
        XCTAssertEqual(p.flow, "")           // absent flow = plain VLESS over REALITY
        XCTAssertEqual(p.fallbackName, "h:8443")
        XCTAssertEqual(XrayConnection(host: "h", port: 443, uuid: "u", sni: "s", publicKey: "k", shortID: "").fallbackName, "h")
    }

    func testRejectsOtherSchemesAndTransports() {
        XCTAssertThrowsError(try XrayURI.parse("olcrtc://wbstream?room=x")) {
            XCTAssertEqual($0 as? XrayURI.Error, .invalidScheme)
        }
        XCTAssertThrowsError(try XrayURI.parse("vless://u@h:443?security=tls&sni=s&pbk=k")) {
            XCTAssertEqual($0 as? XrayURI.Error, .unsupported("security=tls"))
        }
        XCTAssertThrowsError(try XrayURI.parse("vless://u@h:443?security=reality&sni=s&pbk=k&type=ws")) {
            XCTAssertEqual($0 as? XrayURI.Error, .unsupported("type=ws"))
        }
        XCTAssertThrowsError(try XrayURI.parse("vless://u@h:443?security=reality&sni=s")) {
            XCTAssertEqual($0 as? XrayURI.Error, .missingField("pbk"))
        }
        XCTAssertThrowsError(try XrayURI.parse("vless://@h:443?security=reality&sni=s&pbk=k")) {
            XCTAssertEqual($0 as? XrayURI.Error, .missingField("uuid"))
        }
    }

    func testMatchesRoutesOnlyVlessLinks() {
        XCTAssertTrue(XrayURI.matches("  VLESS://u@h?security=reality "))
        XCTAssertFalse(XrayURI.matches("olcrtc://wbstream?room=x"))
        XCTAssertFalse(XrayURI.matches("https://example.com/sub.md"))
    }

    func testDetectImportRoutesVlessAsConnectionURI() {
        guard case .connectionURI(let uri) = OlcrtcSubscription.detectImport(canonical) else {
            return XCTFail("vless link must import as a single connection")
        }
        XCTAssertEqual(uri, canonical)
    }

    func testConnectionDetailsSurface() throws {
        let p = try XrayURI.parse(canonical).params
        let d = ConnectionDetails.xray(p)
        XCTAssertEqual(d.protocolType, .xray)
        XCTAssertFalse(d.isOlcrtc)
        XCTAssertEqual(d.fallbackName, "203.0.113.7")
        XCTAssertTrue(d.subtitle.contains("www.example.com"))
        XCTAssertEqual(try XrayURI.parse(d.shareURI).params, p)
    }

    func testValidateXray() throws {
        var p = try XrayURI.parse(canonical).params
        XCTAssertNil(TunnelManager.validate(xray: p))
        p.uuid = ""
        XCTAssertNotNil(TunnelManager.validate(xray: p))
        p.uuid = "u"; p.port = 70000
        XCTAssertNotNil(TunnelManager.validate(xray: p))
    }

    func testHealthReasonMapping() {
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "keyMismatch"), .keyMismatch)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "hostUnreachable"), .hostUnreachable)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "timedOut"), .timedOut)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "carrierRejected"), .carrierRejected)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "networkDown"), .networkDown)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "dnsUnreachable"), .dnsUnreachable)
        XCTAssertEqual(HealthFailureMapper.reason(forXrayReason: "somethingNew"), .unknown)
    }

    func testOlcosEnvelopeDecoding() throws {
        let ok = #"{"ok":true,"result":{"socks_addr":"127.0.0.1:18089","owns_tun":false}}"#
        let r = try OlcosBridge.decode(ok, as: OlcosBridge.StartResult.self, method: "engine.start")
        XCTAssertEqual(r.socks_addr, "127.0.0.1:18089")
        XCTAssertEqual(OlcosBridge.port(fromSocksAddr: r.socks_addr), 18089)
        XCTAssertThrowsError(try OlcosBridge.decode(#"{"ok":false,"error":"engine already running"}"#,
                                                    as: OlcosBridge.StartResult.self, method: "engine.start")) {
            XCTAssertEqual(($0 as? OlcosBridge.InvokeError)?.message, "engine already running")
        }
        let ev = OlcosBridge.healthEvent(fromLogLine: #"health:{"reason":"keyMismatch","raw":"REALITY: processed invalid connection"}"#)
        XCTAssertEqual(ev?.reason, "keyMismatch")
        XCTAssertNil(OlcosBridge.healthEvent(fromLogLine: "xray 25.x started"))
    }

    // MARK: VPNConfig

    func testVPNConfigXrayRoundTrip() throws {
        let p = try XrayURI.parse(canonical).params
        let cfg = VPNConfig(from: p, dns: "1.1.1.1:53", timeoutMs: 8000)
        XCTAssertTrue(cfg.isXray)
        XCTAssertTrue(cfg.hasCredentials)
        XCTAssertEqual(cfg.keyHex, "")
        XCTAssertEqual(cfg.roomID, "203.0.113.7:443")
        let dict = cfg.providerConfiguration()
        XCTAssertEqual(dict["engine"] as? String, "xray")
        let back = VPNConfig(providerConfiguration: dict)
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(try XrayURI.parse(back!.xrayLink).params, p)
        // The link carries the UUID — it must be scrubbed with the other secrets.
        XCTAssertTrue(VPNConfig.secretConfigKeys.contains("xrayLink"))
    }

    func testVPNConfigOldProfileDecodesAsOlcrtc() {
        let old = VPNConfig(carrier: "telemost", transport: "datachannel", roomID: "r", clientID: "c",
                            keyHex: String(repeating: "a", count: 64), dns: "1.1.1.1:53")
        var dict = old.providerConfiguration()
        dict.removeValue(forKey: "engine")
        dict.removeValue(forKey: "xrayLink")
        let back = VPNConfig(providerConfiguration: dict)
        XCTAssertEqual(back?.engine, VPNConfig.engineOlcrtc)
        XCTAssertFalse(back?.isXray ?? true)
        XCTAssertTrue(back?.hasCredentials ?? false)
    }

    func testVPNConfigScrubbedXrayHasNoCredentials() throws {
        var cfg = VPNConfig(from: try XrayURI.parse(canonical).params, dns: "1.1.1.1:53", timeoutMs: 0)
        cfg.xrayLink = ""
        XCTAssertFalse(cfg.hasCredentials)
    }
}
