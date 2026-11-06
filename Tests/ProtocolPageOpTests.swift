import XCTest
@testable import olcrtc_ios

// A protocol page reports its own actions: the decision of how an action ended
// is pure and pinned here. The actions report a failure by raising an alert (or
// by the host card's failed state) and a success by a sentence of their own.
final class ProtocolPageOpTests: XCTestCase {

    private func outcome(alert: String? = nil, ran: Bool = true, hostFailure: String? = nil,
                         questionPending: Bool = false, note: String? = nil,
                         success: String = "Saved") -> ProtocolOpStatus.Phase? {
        ProtocolOpStatus.outcome(alert: alert, ran: ran, hostFailure: hostFailure,
                                 questionPending: questionPending, note: note, success: success)
    }

    func testAnActionThatLeftNothingBehindSucceedsWithItsOwnSentence() {
        XCTAssertEqual(outcome(), .done("Saved"))
    }

    func testASentenceTheActionAnnouncedReplacesTheDefault() {
        XCTAssertEqual(outcome(note: "Added Jitsi/DataChannel — connection saved"),
                       .done("Added Jitsi/DataChannel — connection saved"))
    }

    func testARaisedAlertIsTheFailure() {
        XCTAssertEqual(outcome(alert: "Error: no route"), .failed("Error: no route"))
    }

    func testAnAlertOutranksEverythingElse() {
        XCTAssertEqual(outcome(alert: "boom", ran: false, hostFailure: "other", note: "fine"), .failed("boom"))
    }

    func testAnActionThatDidNothingReportsNothing() {
        XCTAssertNil(outcome(ran: false))
        XCTAssertNil(outcome(ran: false, hostFailure: "stale failure"))
    }

    func testTheHostCardsFailedStateIsTheFailureOfAnActionThatRanThroughIt() {
        XCTAssertEqual(outcome(hostFailure: "SSH login refused"), .failed("SSH login refused"))
    }

    func testAQuestionOnScreenIsNotAResultYet() {
        XCTAssertNil(outcome(questionPending: true))
    }

    func testOnlyARunningActionIsRunning() {
        func status(_ phase: ProtocolOpStatus.Phase) -> ProtocolOpStatus {
            ProtocolOpStatus(container: "c", kind: .verify, phase: phase)
        }
        XCTAssertTrue(status(.running).isRunning)
        XCTAssertFalse(status(.done("ok")).isRunning)
        XCTAssertFalse(status(.failed("no")).isRunning)
    }

    func testTheKindNamesTheRoomItIsAbout() {
        XCTAssertNotEqual(ProtocolOpStatus.Kind.newRoom("a"), .newRoom("b"))
        XCTAssertNotEqual(ProtocolOpStatus.Kind.removeRoom("a"), .reconfigure("a"))
        XCTAssertEqual(ProtocolOpStatus.Kind.reconfigure("a"), .reconfigure("a"))
    }
}
