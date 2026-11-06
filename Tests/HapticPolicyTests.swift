import XCTest
@testable import olcrtc_ios

// Every press gives one light tap, every finished operation one success or
// error: the rules that keep them from doubling are pure and pinned here.
// (Whether a phone actually buzzes is a device check, not a test.)
final class HapticPolicyTests: XCTestCase {

    // MARK: A tap yields to feedback that came just before it

    func testATapWithNothingBeforeItIsGiven() {
        XCTAssertTrue(HapticPolicy.allowsTap(lastFiredAt: nil, now: 100))
    }

    func testATapRightAfterAnActionsOwnFeedbackIsSilent() {
        XCTAssertFalse(HapticPolicy.allowsTap(lastFiredAt: 100, now: 100.0))
        XCTAssertFalse(HapticPolicy.allowsTap(lastFiredAt: 100, now: 100 + HapticPolicy.tapQuietWindow - 0.01))
    }

    func testATapAfterTheQuietWindowIsGiven() {
        XCTAssertTrue(HapticPolicy.allowsTap(lastFiredAt: 100, now: 100 + HapticPolicy.tapQuietWindow + 0.01))
        XCTAssertTrue(HapticPolicy.allowsTap(lastFiredAt: 100, now: 200))
    }

    // MARK: One outcome is one buzz

    private let success = 0
    private let error = 2

    func testTheFirstOutcomeIsGiven() {
        XCTAssertTrue(HapticPolicy.allowsOutcome(code: success, lastCode: nil, lastAt: nil, now: 50))
    }

    func testTheSameOutcomeTwiceInAMomentIsOneBuzz() {
        XCTAssertFalse(HapticPolicy.allowsOutcome(code: success, lastCode: success, lastAt: 50, now: 50.2))
    }

    func testTheSameOutcomeLaterIsGivenAgain() {
        XCTAssertTrue(HapticPolicy.allowsOutcome(code: success, lastCode: success, lastAt: 50,
                                                 now: 50 + HapticPolicy.outcomeRepeatWindow + 0.01))
    }

    func testAnotherOutcomeIsNeverHeldBack() {
        XCTAssertTrue(HapticPolicy.allowsOutcome(code: error, lastCode: success, lastAt: 50, now: 50.1))
    }

    // MARK: A finished check earns the right feedback

    func testAVerifiedCheckIsASuccess() {
        XCTAssertEqual(HealthDisplay.verified(ms: 48, age: 0).finishedCheckFeedback, .success)
        XCTAssertEqual(HealthDisplay.verified(ms: nil, age: 3).finishedCheckFeedback, .success)
    }

    func testACheckThatFoundAFaultOrCouldNotRunIsAnError() {
        XCTAssertEqual(HealthDisplay.broken(.keyMismatch, age: 1).finishedCheckFeedback, .error)
        XCTAssertEqual(HealthDisplay.handshakeOnly(age: 1).finishedCheckFeedback, .error)
        XCTAssertEqual(HealthDisplay.inconclusive(.hostUnreachable, age: 1).finishedCheckFeedback, .error)
    }

    func testStatesAFinishedCheckDoesNotEndInGiveNothing() {
        for state in [HealthDisplay.never, .checking, .fading(ms: 10, age: 600), .stale(age: 7200)] {
            XCTAssertNil(state.finishedCheckFeedback, "\(state)")
        }
    }
}
