import XCTest
@testable import olcrtc_ios

/// M7: a Keychain write that failed used to be remembered as written, so the list was saved without the
/// key and the key was gone at the next launch. Pure decisions only; the Keychain itself is integration.
final class SecretLedgerTests: XCTestCase {
    func testASecretTheSlotAlreadyHoldsIsNotWrittenAgain() {
        XCTAssertFalse(SecretLedger.needsWrite("k", held: "k"))
    }

    func testANewOrChangedSecretIsWritten() {
        XCTAssertTrue(SecretLedger.needsWrite("k", held: nil))
        XCTAssertTrue(SecretLedger.needsWrite("k2", held: "k"))
    }

    func testAWriteTheKeychainTookIsRemembered() {
        XCTAssertEqual(SecretLedger.afterWrite("k", held: nil, succeeded: true), "k")
        XCTAssertEqual(SecretLedger.afterWrite("k2", held: "k", succeeded: true), "k2")
    }

    func testARefusedWriteIsNotRememberedSoTheNextSaveTriesAgain() {
        let held = SecretLedger.afterWrite("k", held: nil, succeeded: false)
        XCTAssertNil(held)
        XCTAssertTrue(SecretLedger.needsWrite("k", held: held))
    }

    func testARefusedChangeKeepsWhatTheKeychainHeldBefore() {
        let held = SecretLedger.afterWrite("k2", held: "k", succeeded: false)
        XCTAssertEqual(held, "k")
        XCTAssertTrue(SecretLedger.needsWrite("k2", held: held))
    }
}
