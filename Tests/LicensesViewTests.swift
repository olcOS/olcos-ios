import XCTest
@testable import olcrtc_ios

// The licence screen reads bundled texts: they must be in the app bundle, and
// cutting a long document into chunks must not lose a character.

final class LicensesViewTests: XCTestCase {

    func testEveryDocumentIsBundled() {
        for resource in ["LICENSE", "olcrtc-NOTICE", "olcrtc-LICENSE", "olcrtc-upstream-WTFPL",
                         "third-party-go", "third-party-swift"] {
            XCTAssertFalse(LicenseTextView.load(resource).isEmpty, resource)
        }
        XCTAssertTrue(LicenseTextView.load("olcrtc-LICENSE").contains("Apache License"))
    }

    func testChunksRestoreTheText() {
        let text = (0..<200).map { "Paragraph \($0) with some words in it." }.joined(separator: "\n\n")
        let chunks = LicenseTextView.chunks(of: text, target: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
        XCTAssertEqual(LicenseTextView.chunks(of: ""), [])
    }
}
