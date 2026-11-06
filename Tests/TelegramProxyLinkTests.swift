import XCTest
@testable import olcrtc_ios

// The one-tap Telegram proxy link: loopback server, the bound port, and the
// local login only when both halves exist — escaped so a password with `&`,
// `=` or `+` arrives intact.

final class TelegramProxyLinkTests: XCTestCase {

    func testAppLinkWithoutLogin() {
        XCTAssertEqual(TelegramProxyLink.appURL(port: 8808)?.absoluteString,
                       "tg://socks?server=127.0.0.1&port=8808")
    }

    func testWebFallbackCarriesTheSameQuery() {
        XCTAssertEqual(TelegramProxyLink.webURL(port: 1080)?.absoluteString,
                       "https://t.me/socks?server=127.0.0.1&port=1080")
    }

    func testLoginIsEscaped() throws {
        let url = try XCTUnwrap(TelegramProxyLink.appURL(port: 8808, user: "me", pass: "a&b=c+d e"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "user" }?.value, "me")
        XCTAssertEqual(items.first { $0.name == "pass" }?.value, "a&b=c+d e")
        XCTAssertFalse(url.absoluteString.contains("+"), "a literal + would read as a space")
    }

    func testHalfALoginIsLeftOut() {
        XCTAssertEqual(TelegramProxyLink.appURL(port: 8808, user: "me", pass: "")?.absoluteString,
                       "tg://socks?server=127.0.0.1&port=8808")
        XCTAssertEqual(TelegramProxyLink.appURL(port: 8808, user: nil, pass: "secret")?.absoluteString,
                       "tg://socks?server=127.0.0.1&port=8808")
    }

    func testImpossiblePortsMakeNoLink() {
        XCTAssertNil(TelegramProxyLink.appURL(port: 0))
        XCTAssertNil(TelegramProxyLink.appURL(port: 70_000))
    }
}
