import XCTest
@testable import olcrtc_ios

// `BestChoice` decides which connection the app recommends. It may only claim
// what was measured: a fresh round trip beats a slower fresh round trip or a
// known failure, never a node nobody checked, and never by a margin that is
// measurement noise.

final class BestChoiceTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    private func pick(_ nodes: [(UUID, HealthDisplay)]) -> UUID? {
        BestChoice.pick(nodes.map { (id: $0.0, display: $0.1) })
    }

    func testAClearLeadPicksTheFasterNode() {
        XCTAssertEqual(pick([(a, .verified(ms: 72, age: 10)), (b, .verified(ms: 120, age: 30))]), a)
        XCTAssertEqual(pick([(a, .verified(ms: 120, age: 10)), (b, .verified(ms: 72, age: 30))]), b)
    }

    func testALeadInsideMeasurementNoiseIsATie() {
        XCTAssertNil(pick([(a, .verified(ms: 72, age: 10)), (b, .verified(ms: 76, age: 10))]))
        // 10 % of the runner-up: 300 against 320 needs a 32 ms lead.
        XCTAssertNil(pick([(a, .verified(ms: 300, age: 10)), (b, .verified(ms: 320, age: 10))]))
        XCTAssertEqual(pick([(a, .verified(ms: 288, age: 10)), (b, .verified(ms: 320, age: 10))]), a)
    }

    func testTheLeadNeverFallsBelowTheFloor() {
        XCTAssertNil(pick([(a, .verified(ms: 20, age: 10)), (b, .verified(ms: 24, age: 10))]))
        XCTAssertEqual(pick([(a, .verified(ms: 20, age: 10)), (b, .verified(ms: 25, age: 10))]), a)
    }

    func testOnlyTheTopTwoDecide() {
        // The third node is far behind, but the leaders are tied.
        XCTAssertNil(pick([(a, .verified(ms: 70, age: 1)),
                           (b, .verified(ms: 72, age: 1)),
                           (c, .verified(ms: 400, age: 1))]))
    }

    func testTheOnlyWorkingNodeBesideKnownFailuresWins() {
        XCTAssertEqual(pick([(a, .verified(ms: 300, age: 10)), (b, .broken(.keyMismatch, age: 60))]), a)
        XCTAssertEqual(pick([(a, .verified(ms: 90, age: 10)), (b, .handshakeOnly(age: 60))]), a)
    }

    func testAVerifiedNodeBesideUncheckedNodesIsNotTheBestOfAnything() {
        for other: HealthDisplay in [.never, .checking, .stale(age: 4000),
                                     .fading(ms: 40, age: 600),
                                     .inconclusive(.hostUnreachable, age: 30)] {
            XCTAssertNil(pick([(a, .verified(ms: 80, age: 10)), (b, other)]), "\(other)")
        }
    }

    func testAWorkingNodeWithoutARoundTripWithholdsTheClaim() {
        // It might be the fastest; nobody measured it.
        XCTAssertNil(pick([(a, .verified(ms: nil, age: 5)),
                           (b, .verified(ms: 80, age: 5)),
                           (c, .broken(.noPeer, age: 5))]))
    }

    func testFailuresAloneNameNoWinner() {
        XCTAssertNil(pick([(a, .broken(.keyMismatch, age: 1)), (b, .broken(.noPeer, age: 1))]))
        XCTAssertNil(pick([]))
        XCTAssertNil(pick([(a, .verified(ms: 50, age: 1))]))
    }
}

// The coordinator judges the STORED verdicts, so a node being re-checked
// keeps its standing and the mark does not hop for the length of a probe.
@MainActor
final class BestChoiceCoordinatorTests: XCTestCase {

    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?

    override func setUp() {
        super.setUp()
        HealthCoordinator.flushPendingWrites()
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)
    }

    override func tearDown() {
        HealthCoordinator.flushPendingWrites()
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        super.tearDown()
    }

    func testPicksFromStoredMeasurements() {
        let coordinator = HealthCoordinator(loadPersisted: false)
        let fast = UUID(), slow = UUID(), unknown = UUID()
        coordinator.noteLiveVerified(recordID: fast, rttMs: 60)
        coordinator.noteLiveVerified(recordID: slow, rttMs: 240)
        XCTAssertEqual(coordinator.bestChoice(among: [fast, slow, unknown]), fast)

        // Forgetting the winner leaves one measured node and nothing to beat.
        coordinator.forget(recordID: fast)
        XCTAssertNil(coordinator.bestChoice(among: [fast, slow, unknown]))
    }

    func testAMeasurementPastTheFreshWindowNoLongerCompetes() {
        let coordinator = HealthCoordinator(loadPersisted: false)
        let x = UUID(), y = UUID()
        coordinator.noteLiveVerified(recordID: x, rttMs: 60)
        coordinator.noteLiveVerified(recordID: y, rttMs: 240)
        let later = Date().addingTimeInterval(HealthPolicy.freshSeconds + 1)
        XCTAssertNil(coordinator.bestChoice(among: [x, y], now: later))
    }
}
