import XCTest
@testable import olcrtc_ios

// The first-run screen reads a picked file as text before handing it to the
// import; anything binary is refused rather than parsed.

final class WelcomeViewTests: XCTestCase {

    func testFilesAreReadAsTextOnly() {
        XCTAssertEqual(WelcomeView.text(from: Data([0xEF, 0xBB, 0xBF] + Array("olcrtc://x".utf8))), "olcrtc://x")
        XCTAssertEqual(WelcomeView.text(from: Data("vless://a@b:443".utf8)), "vless://a@b:443")
        XCTAssertNil(WelcomeView.text(from: Data([0x00, 0x01, 0xFF])))
        XCTAssertNil(WelcomeView.text(from: Data("a\u{0}b".utf8)))
    }
}
