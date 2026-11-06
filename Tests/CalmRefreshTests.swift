import XCTest
@testable import olcrtc_ios

// The Connections tab and the server card stay still while checks run: the
// decisions behind that are pure and pinned here — what a row shows while it is
// re-measured, when the ageing clock may redraw, how a listing is compared
// before it is assigned, and how fast the agent's events may trigger a re-read.
@MainActor
final class CalmRefreshTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func working(agoSeconds: TimeInterval, ms: Int = 48) -> NodeHealth {
        NodeHealth(kind: .working, checkedAt: now.addingTimeInterval(-agoSeconds), rttMs: ms, source: "probe")
    }

    // MARK: A value that is being re-measured stays on screen

    func testReCheckKeepsTheLastVerdictOnScreen() {
        let shown = HealthCoordinator.settledDisplay(for: working(agoSeconds: 10), checking: true, now: now)
        XCTAssertEqual(shown, .verified(ms: 48, age: 10))
        XCTAssertFalse(shown.isChecking)
    }

    func testReCheckKeepsAnOlderVerdictToo() {
        let broken = NodeHealth(kind: .broken, checkedAt: now.addingTimeInterval(-60),
                                reason: .keyMismatch, source: "probe")
        XCTAssertEqual(HealthCoordinator.settledDisplay(for: broken, checking: true, now: now),
                       .broken(.keyMismatch, age: 60))
    }

    func testOnlyANeverMeasuredRecordReadsChecking() {
        XCTAssertEqual(HealthCoordinator.settledDisplay(for: nil, checking: true, now: now), .checking)
        XCTAssertEqual(HealthCoordinator.settledDisplay(for: nil, checking: false, now: now), .never)
    }

    func testSettledDisplayWithoutACheckIsTheOrdinaryDisplay() {
        let h = working(agoSeconds: 600)
        XCTAssertEqual(HealthCoordinator.settledDisplay(for: h, checking: false, now: now),
                       HealthCoordinator.display(for: h, checking: false, now: now))
    }

    // MARK: The ageing clock redraws only when a verdict crosses a boundary

    func testAgePhaseChangesOnlyAtTheTwoBoundaries() {
        func phase(_ ago: TimeInterval) -> Int {
            HealthCoordinator.agePhase(of: working(agoSeconds: ago), now: now)
        }
        XCTAssertEqual(phase(0), 0)
        XCTAssertEqual(phase(HealthPolicy.freshSeconds - 1), 0)
        XCTAssertEqual(phase(HealthPolicy.freshSeconds), 1)
        XCTAssertEqual(phase(HealthPolicy.staleSeconds - 1), 1)
        XCTAssertEqual(phase(HealthPolicy.staleSeconds), 2)
        XCTAssertEqual(phase(HealthPolicy.staleSeconds * 10), 2)
    }

    func testAMinuteInsideOnePhaseIsNotAChange() {
        let store = ["a": working(agoSeconds: 30), "b": working(agoSeconds: 400)]
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(HealthCoordinator.agePhases(of: store, now: now),
                       HealthCoordinator.agePhases(of: store, now: later))
    }

    func testCrossingTheFreshBoundaryIsAChange() {
        let store = ["a": working(agoSeconds: HealthPolicy.freshSeconds - 30)]
        let later = now.addingTimeInterval(60)
        XCTAssertNotEqual(HealthCoordinator.agePhases(of: store, now: now),
                          HealthCoordinator.agePhases(of: store, now: later))
    }

    // MARK: A snapshot that found the same base redraws nothing

    func testSnapshotWithTheSameBaseDoesNotBumpTheRevision() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        health.noteHostSnapshot(HostSnapshot(base: .running, probedAt: now), for: id)
        let before = health.revision
        health.noteHostSnapshot(HostSnapshot(base: .running, probedAt: now.addingTimeInterval(30),
                                             disk: "1G/2G", pingMs: 41), for: id)
        XCTAssertEqual(health.revision, before)
        XCTAssertEqual(health.hostSnapshot(for: id)?.pingMs, 41, "the newer reading is still kept")
    }

    func testSnapshotWithANewBaseBumpsTheRevision() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        health.noteHostSnapshot(HostSnapshot(base: .running, probedAt: now), for: id)
        let before = health.revision
        health.noteHostSnapshot(HostSnapshot(base: .stopped, probedAt: now), for: id)
        XCTAssertNotEqual(health.revision, before)
    }

    // MARK: A listing is compared by what the card shows

    private func row(_ container: String, room: String = "room", status: ContainerStatus,
                     primary: Bool = true) -> SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(file: primary ? "server.yaml" : "server-\(container).yaml",
                              provider: "jitsi", transport: "datachannel", room: room,
                              container: container, status: status, isPrimary: primary)
    }

    func testUptimeTextIsNotAChangeOfTheListing() {
        let shown = [row("a", status: .running("Up 3 minutes"))]
        let read = [row("a", status: .running("Up 4 minutes"))]
        XCTAssertTrue(ServerPresentationPolicy.sameListing(shown, read))
    }

    func testARoomOrAStateChangeIsAChangeOfTheListing() {
        let shown = [row("a", status: .running("Up 3 minutes"))]
        XCTAssertFalse(ServerPresentationPolicy.sameListing(shown, [row("a", room: "other", status: .running("Up 3 minutes"))]))
        XCTAssertFalse(ServerPresentationPolicy.sameListing(shown, [row("a", status: .stopped("Exited (0) 1 minute ago"))]))
        XCTAssertFalse(ServerPresentationPolicy.sameListing(shown, [row("a", status: .notFound)]))
    }

    func testListingWithAnotherCountOrNothingShownIsAChange() {
        let one = [row("a", status: .notFound)]
        XCTAssertFalse(ServerPresentationPolicy.sameListing(nil, one))
        XCTAssertFalse(ServerPresentationPolicy.sameListing(nil, []))
        XCTAssertFalse(ServerPresentationPolicy.sameListing(one, []))
        XCTAssertTrue(ServerPresentationPolicy.sameListing([], []))
    }

    // MARK: The agent's events re-read at most once per interval

    func testFirstEventIsReadAtOnce() {
        XCTAssertEqual(AgentEventCoalescing.delay(lastRefresh: nil, now: now), 0)
    }

    func testAnEventRightAfterAReadWaitsOutTheInterval() {
        let last = now.addingTimeInterval(-5)
        XCTAssertEqual(AgentEventCoalescing.delay(lastRefresh: last, now: now),
                       AgentEventCoalescing.minInterval - 5, accuracy: 0.001)
    }

    func testAnOldReadLeavesNothingToWaitFor() {
        let last = now.addingTimeInterval(-AgentEventCoalescing.minInterval - 1)
        XCTAssertEqual(AgentEventCoalescing.delay(lastRefresh: last, now: now), 0)
    }

    func testTheIntervalIsHalfAMinute() {
        XCTAssertEqual(AgentEventCoalescing.minInterval, 30)
    }
}
