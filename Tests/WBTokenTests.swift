import XCTest
@testable import olcrtc_ios

// #436: wbstream account token (auth.token). WB Stream is no longer offered, but
// a saved wbstream connection still carries its token. Verifies the
// security-relevant invariants: no install sends a token any more, the token
// never lands in UserDefaults JSON (Keychain-only, like key/socksPass), and it is
// redacted from logs (install-command preview / config echo).

@MainActor
final class WBTokenTests: XCTestCase {

    // MARK: server env

    func testInstallEnvNeverEmitsAToken() {
        for carrier in ["wbstream", "jitsi"] {
            let env = SSHRunner.installEnv(
                InstallOptions(carrier: carrier, transport: "datachannel", roomID: "room1"))
            XCTAssertFalse(env.contains("OLCRTC_WB_TOKEN"), carrier)
        }
    }

    // MARK: never serialised to UserDefaults (the classic secret-leak bug)

    func testTokenExcludedFromCodable() throws {
        let conn = OlcrtcConnection(carrier: "wbstream", transport: "datachannel",
                                    roomID: "r", key: "k", clientID: "default",
                                    wbToken: "tok_secret_123")
        let json = String(data: try JSONEncoder().encode(conn), encoding: .utf8)!
        XCTAssertFalse(json.contains("tok_secret_123"), "token must never reach UserDefaults JSON")
        XCTAssertFalse(json.lowercased().contains("wbtoken"))
        // And a decoded connection starts with an empty token (restored from Keychain).
        let decoded = try JSONDecoder().decode(OlcrtcConnection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.wbToken, "")
    }

    // MARK: redaction

    func testRedactionScrubsEnvAndYamlToken() {
        let env = LogStore.redactSecrets("$ OLCRTC_WB_TOKEN=tok_secret_123 OLCRTC_CARRIER=wbstream ./srv.sh")
        XCTAssertFalse(env.contains("tok_secret_123"))
        XCTAssertTrue(env.contains("OLCRTC_WB_TOKEN=<redacted>"))

        let yaml = LogStore.redactSecrets(#"  token: "tok_secret_123""#)
        XCTAssertFalse(yaml.contains("tok_secret_123"))
        XCTAssertTrue(yaml.contains("<redacted>"))
    }
}
