import XCTest
@testable import olcrtc_ios

// The SSH full-access link (`olcrtc://host/v1/<base64url>`) is no longer
// imported: a device invite with management access replaced it. An old link
// that is opened or pasted is still recognised by its shape, so it is answered
// with one line instead of being read as a connection.

final class RetiredFullAccessLinkTests: XCTestCase {

    /// A link as older versions produced it (base64url JSON, no padding).
    private let oldLink = "olcrtc://host/v1/eyJmb3JtYXRWZXJzaW9uIjoxLCJsYWJlbCI6IkwiLCJzc2hIb3N0IjoiaCJ9"

    func testOldFullAccessLinkIsRecognised() {
        XCTAssertTrue(RetiredFullAccessLink.matches(oldLink))
        XCTAssertTrue(RetiredFullAccessLink.matches("  \(oldLink)\n"))
        XCTAssertTrue(RetiredFullAccessLink.matches("olcrtc://host/v2/abc"))
    }

    func testConnectionAndInviteLinksAreNotMistakenForIt() {
        let key = String(repeating: "a", count: 64)
        XCTAssertFalse(RetiredFullAccessLink.matches("olcrtc://telemost?vp8channel@room#\(key)"))
        XCTAssertFalse(RetiredFullAccessLink.matches("olcrtc://jitsi?datachannel@https://meet.example.org/room#\(key)"))
        XCTAssertFalse(RetiredFullAccessLink.matches("olcrtc-sub://example.org/sub.md"))
        XCTAssertFalse(RetiredFullAccessLink.matches("https://example.org/host/v1/abc"))
        XCTAssertFalse(RetiredFullAccessLink.matches(""))
    }

    /// Such a link never parses as a connection, so the notice is the only answer.
    func testOldLinkIsNotAConnection() {
        XCTAssertThrowsError(try OlcrtcURI.parse(oldLink))
    }

    func testNoticeAsksForAnInviteInEveryLanguage() {
        XCTAssertEqual(L10n.fullAccessLinkRetired.localized(.russian),
                       "Ссылки с полным доступом по SSH больше не поддерживаются — попросите приглашение с доступом к управлению.")
        XCTAssertEqual(L10n.fullAccessLinkRetired.localized(.english),
                       "Links with full SSH access are no longer supported — ask for an invite with management access.")
        XCTAssertFalse(L10n.fullAccessLinkRetired.localized(.french).isEmpty)
        XCTAssertNotEqual(L10n.fullAccessLinkRetired.localized(.french),
                          L10n.fullAccessLinkRetired.localized(.english))
    }

    func testNoticeFollowsTheAppLanguage() {
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }
        SettingsStore.shared.language = "en"
        XCTAssertEqual(RetiredFullAccessLink.notice, L10n.fullAccessLinkRetired.localized(.english))
    }
}
