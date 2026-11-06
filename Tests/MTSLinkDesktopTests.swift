import XCTest
@testable import olcrtc_ios

// The desktop disguise of the MTS Link sheet and replay page: which links the
// web view refuses, how addresses reach the log, and what the document-start
// script overrides. The web views themselves are integration-only.

final class MTSLinkDesktopTests: XCTestCase {

    private func decide(_ text: String) -> MTSLinkDesktop.LinkDecision {
        MTSLinkDesktop.decide(URL(string: text))
    }

    // MARK: Identity

    func testTheUserAgentIsDesktopChromeOnWindows() {
        let agent = MTSLinkRoomService.desktopUserAgent
        XCTAssertTrue(agent.hasPrefix("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"))
        XCTAssertTrue(agent.contains("Chrome/"))
        XCTAssertFalse(agent.contains("Mobile"))
        XCTAssertFalse(agent.contains("iPhone"))
    }

    // MARK: Links

    func testWebAddressesAreFollowed() {
        XCTAssertEqual(decide("https://my.mts-link.ru/j/1/2"), .allow)
        XCTAssertEqual(decide("http://example.com/"), .allow)
        XCTAssertEqual(decide("HTTPS://my.mts-link.ru/"), .allow)
    }

    func testPagesThatStayInsideTheViewAreFollowed() {
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertEqual(decide("blob:https://my.mts-link.ru/abc"), .allow)
        XCTAssertEqual(MTSLinkDesktop.decide(nil), .allow)
    }

    func testLinksToAnAppAreBlockedByTheirScheme() {
        XCTAssertEqual(decide("mtslink://join?room=1"), .blocked("mtslink"))
        XCTAssertEqual(decide("intent://my.mts-link.ru/j/1#Intent;scheme=https;end"), .blocked("intent"))
        XCTAssertEqual(decide("itms-apps://apps.apple.com/app/id1"), .blocked("itms-apps"))
        XCTAssertEqual(decide("tel:+70000000000"), .blocked("tel"))
        XCTAssertEqual(decide("MAILTO:someone@example.com"), .blocked("mailto"))
    }

    func testAppStorePagesAreBlocked() {
        XCTAssertEqual(decide("https://apps.apple.com/ru/app/mts-link/id123"), .blocked("app-store"))
        XCTAssertEqual(decide("https://itunes.apple.com/app/id123"), .blocked("app-store"))
        XCTAssertEqual(decide("https://play.google.com/store/apps/details?id=ru.mts.link"), .blocked("app-store"))
        XCTAssertEqual(decide("https://play.google.com/about"), .allow)
        XCTAssertEqual(decide("https://notapps.apple.com.example.org/"), .allow)
    }

    func testOnlyWebAddressesOpenInTheSameView() {
        XCTAssertTrue(MTSLinkDesktop.opensInSameView(URL(string: "https://my.mts-link.ru/j/1/2")))
        XCTAssertFalse(MTSLinkDesktop.opensInSameView(URL(string: "about:blank")))
        XCTAssertFalse(MTSLinkDesktop.opensInSameView(nil))
    }

    // MARK: Log lines

    func testLoggedAddressesCarryNoQueryFragmentOrCredentials() {
        XCTAssertEqual(MTSLinkDesktop.loggable(URL(string: "https://my.mts-link.ru/j/1/2?token=secret#frag")),
                       "https://my.mts-link.ru/j/1/2")
        XCTAssertEqual(MTSLinkDesktop.loggable(URL(string: "https://user:pass@my.mts-link.ru/a")),
                       "https://my.mts-link.ru/a")
        XCTAssertEqual(MTSLinkDesktop.loggable(URL(string: "mtslink://join?room=secret")), "mtslink:")
        XCTAssertEqual(MTSLinkDesktop.loggable(nil), "(no address)")
    }

    func testTheLogLinesSayWhatHappened() {
        XCTAssertEqual(MTSLinkDesktop.blockedLine("mtslink"),
                       "blocked mtslink link (the site wanted the MTS Link app)")
        XCTAssertEqual(MTSLinkDesktop.newWindowLine(URL(string: "https://my.mts-link.ru/j/1/2?x=1")),
                       "new window → same view: https://my.mts-link.ru/j/1/2")
    }

    // MARK: The document-start script

    func testTheScriptOverridesWhatTheTouchScreenGivesAway() {
        let script = MTSLinkDesktop.shimScript
        for needle in ["maxTouchPoints", "\"Win32\"", "ontouchstart", "ontouchmove", "ontouchend",
                       "Window.prototype", "Document.prototype", "HTMLElement.prototype",
                       "matchMedia", "coarse", "fine", "hover"] {
            XCTAssertTrue(script.contains(needle), "the script lacks \(needle)")
        }
    }

    func testTheScriptIsGuardedAndBalanced() {
        let script = MTSLinkDesktop.shimScript
        XCTAssertTrue(script.contains("catch"))
        XCTAssertEqual(script.filter { $0 == "{" }.count, script.filter { $0 == "}" }.count)
        XCTAssertEqual(script.filter { $0 == "[" }.count, script.filter { $0 == "]" }.count)
    }
}
