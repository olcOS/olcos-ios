import XCTest
@testable import olcrtc_ios

// A protocol whose container is not running is stopped, not broken: it is not
// checked on its own, it counts neither as working nor as failed, it is never
// named under «Not responding», and a whole-server connection names its room
// as stopped. Everything here is pure; the rows that draw it are visual.
@MainActor
final class StoppedProtocolTests: XCTestCase {

    private var savedLanguage = "en"
    private let key = String(repeating: "ab", count: 32)
    private let verified = HealthDisplay.verified(ms: 40, age: 20)
    private let failed = HealthDisplay.broken(.noPeer, age: 60)

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    private func mark(_ name: String, _ display: HealthDisplay, stopped: Bool = false) -> ProtocolMark {
        ProtocolMark(name: name, display: display, stopped: stopped)
    }

    private func headline(_ tally: ProtocolsTally, summary: HealthDisplay) -> HostHeadline {
        HostHeadline.reduce(display: .base(.running), reachable: true, lastProbeAge: 5,
                            health: summary, tally: tally)
    }

    private func record(_ carrier: String, _ room: String) -> ConnectionRecord {
        ConnectionRecord(name: "srv · \(carrier)", details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: "datachannel", roomID: room, key: key, clientID: "default")))
    }

    private func row(_ carrier: String, _ room: String, up: Bool, primary: Bool = false) -> SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(file: primary ? "server.yaml" : "server-\(carrier).yaml",
                              provider: carrier, transport: "datachannel", room: room,
                              container: primary ? "olcrtc-server-test" : "olcrtc-server-test-\(carrier)",
                              status: up ? .running("Up 3 minutes") : .stopped("Exited (0) 1 minute ago"),
                              isPrimary: primary)
    }

    // MARK: The tally

    func testAStoppedProtocolCountsNeitherAsWorkingNorAsFailed() {
        let tally = ProtocolsTally.make([mark("Jitsi", verified), mark("MTS Link", failed, stopped: true)], rows: 2)
        XCTAssertEqual(tally.working, 1)
        XCTAssertEqual(tally.total, 1, "a stopped protocol is out of the count")
        XCTAssertEqual(tally.failed, [], "an old failure of a stopped protocol is not a failure now")
        XCTAssertEqual(tally.stopped, ["MTS Link"])
        let h = headline(tally, summary: verified)
        XCTAssertEqual(h.title, L10n.healthVerified.localized())
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineProtocolsWorking_fmt.formatted(1, 1))
        XCTAssertNil(h.problemLine, "a stopped protocol is never «not responding»")
    }

    func testEveryProtocolStoppedReadsStopped() {
        let tally = ProtocolsTally.make([mark("Jitsi", .never, stopped: true),
                                         mark("MTS Link", failed, stopped: true)], rows: 2)
        XCTAssertEqual(tally.total, 0)
        XCTAssertEqual(tally.standing(fallback: failed), .stopped)
        let h = headline(tally, summary: failed)
        XCTAssertEqual(h.title, L10n.protocolStopped.localized())
        XCTAssertEqual(h.tone, .unknown, "stopped is grey, not red")
        XCTAssertEqual(h.subtitle, L10n.protocolStoppedNote.localized())
        XCTAssertNil(h.problemLine)
    }

    func testAStoppedRowWithoutARecordIsNotCountedEither() {
        // Three rows: one verified, one stopped (its mark carries it) and one
        // running with no saved record.
        let tally = ProtocolsTally.make([mark("Jitsi", verified), mark("VK Calls", .never, stopped: true)], rows: 3)
        XCTAssertEqual(tally.total, 2)
        XCTAssertEqual(tally.working, 1)
    }

    func testAStoppedProtocolBesideAFailedOneLeavesTheFailureNamed() {
        let tally = ProtocolsTally.make([mark("Telemost", failed), mark("MTS Link", failed, stopped: true)], rows: 2)
        XCTAssertEqual(tally.standing(fallback: failed), .failed)
        XCTAssertEqual(tally.problemLine, L10n.protocolsNotResponding_fmt.formatted("Telemost"))
    }

    func testStoppedWords() {
        XCTAssertEqual(ProtocolStanding.stopped.title, L10n.protocolStopped.localized())
        XCTAssertEqual(ProtocolStanding.stopped.tone, .unknown)
    }

    // MARK: The whole-server connection

    func testAWholeServerConnectionNamesAStoppedRoomAsStopped() {
        let marks = [mark("Jitsi", verified), mark("MTS Link", failed, stopped: true)]
        let tally = ProtocolsTally.make(marks, rows: marks.count)
        XCTAssertNil(tally.problemLine)
        XCTAssertEqual(tally.stoppedLine, L10n.roomsStoppedOne_fmt.formatted("MTS Link"))
        XCTAssertEqual(tally.roomsNote, L10n.roomsStoppedOne_fmt.formatted("MTS Link"))
        let two = ProtocolsTally.make([mark("Telemost", failed), mark("MTS Link", .never, stopped: true),
                                       mark("VK Calls", .never, stopped: true)], rows: 3)
        XCTAssertEqual(two.stoppedLine, L10n.roomsStoppedMany_fmt.formatted("MTS Link, VK Calls"))
        XCTAssertEqual(two.roomsNote, [L10n.protocolsNotResponding_fmt.formatted("Telemost"),
                                       L10n.roomsStoppedMany_fmt.formatted("MTS Link, VK Calls")]
                                       .joined(separator: "\n"))
        XCTAssertNil(ProtocolsTally.make([mark("Jitsi", verified)], rows: 1).roomsNote)
    }

    // MARK: Which records are stopped

    func testTheRecordsOfStoppedContainersAreStopped() {
        let jitsi = record("jitsi", "https://meet.example/a")
        let mts = record("mtslink", "https://mts.example/j/1/2")
        var host = ServerHost(label: "srv", host: "203.0.113.9")
        host.lastConnectionID = jitsi.id
        host.extraConnectionIDs = [mts.id]
        let rows = [row("jitsi", "https://meet.example/a", up: true, primary: true),
                    row("mtslink", "https://mts.example/j/1/2", up: false)]
        XCTAssertEqual(StoppedProtocols.recordIDs(host: host, rows: rows, records: [jitsi, mts]), [mts.id])
        let missing = [row("jitsi", "https://meet.example/a", up: true, primary: true),
                       SSHRunner.CarrierInfo(file: "server-mtslink.yaml", provider: "mtslink", transport: "datachannel",
                                             room: "https://mts.example/j/1/2", container: "olcrtc-server-test-mtslink",
                                             status: .notFound, isPrimary: false)]
        XCTAssertEqual(StoppedProtocols.recordIDs(host: host, rows: missing, records: [jitsi, mts]), [mts.id],
                       "a container that is not there does not run either")
        let running = [row("jitsi", "https://meet.example/a", up: true, primary: true),
                       row("mtslink", "https://mts.example/j/1/2", up: true)]
        XCTAssertTrue(StoppedProtocols.recordIDs(host: host, rows: running, records: [jitsi, mts]).isEmpty,
                      "once it runs again it is checked again")
    }

    func testARecordARunningRowAlsoResolvesToIsNotStopped() {
        // Two Jitsi rows; the stopped sibling has no record of its own and
        // falls back to the primary's.
        let jitsi = record("jitsi", "https://meet.example/a")
        var host = ServerHost(label: "srv", host: "203.0.113.9")
        host.lastConnectionID = jitsi.id
        let rows = [row("jitsi", "https://meet.example/a", up: true, primary: true),
                    row("jitsi", "https://meet.example/b", up: false)]
        XCTAssertTrue(StoppedProtocols.recordIDs(host: host, rows: rows, records: [jitsi]).isEmpty)
    }

    func testAWholeServerConnectionWhoseFirstRoomIsStoppedIsNotCheckedOnItsOwn() throws {
        let jitsi = record("jitsi", "https://meet.example/a")
        let mts = record("mtslink", "https://mts.example/j/1/2")
        guard case .olcrtc(let j) = jitsi.details, case .olcrtc(let m) = mts.details else { return XCTFail() }
        let params = try XCTUnwrap(ServerBundle.params(protocols: [j, m], bond: nil))
        let bundle = ConnectionRecord(name: "srv", details: .olcrtc(params))
        var host = ServerHost(label: "srv", host: "203.0.113.9")
        host.lastConnectionID = jitsi.id
        host.extraConnectionIDs = [mts.id]
        host.bundleConnectionID = bundle.id
        let records = [bundle, jitsi, mts]
        let firstStopped = [row("jitsi", "https://meet.example/a", up: false, primary: true),
                            row("mtslink", "https://mts.example/j/1/2", up: true)]
        XCTAssertEqual(StoppedProtocols.recordIDs(host: host, rows: firstStopped, records: records),
                       [jitsi.id, bundle.id], "its own check would dial the stopped room")
        let otherStopped = [row("jitsi", "https://meet.example/a", up: true, primary: true),
                            row("mtslink", "https://mts.example/j/1/2", up: false)]
        XCTAssertEqual(StoppedProtocols.recordIDs(host: host, rows: otherStopped, records: records), [mts.id])
    }

    // MARK: The automatic checks

    func testAnAutomaticSweepSkipsStoppedProtocols() {
        let health = HealthCoordinator(loadPersisted: false)
        let jitsi = record("jitsi", "https://meet.example/a")
        let mts = record("mtslink", "https://mts.example/j/1/2")
        let due = health.automaticSweepCandidates([jitsi, mts], keep: [], stopped: [mts.id])
        XCTAssertEqual(due.map(\.id), [jitsi.id])
        let resumed = health.automaticSweepCandidates([jitsi, mts], keep: [], stopped: [])
        XCTAssertEqual(resumed.map(\.id), [jitsi.id, mts.id], "a protocol that runs again is checked again")
    }

    func testTheRoomsOfAStoppedWholeServerConnectionAreCheckedOnTheirOwn() throws {
        let health = HealthCoordinator(loadPersisted: false)
        let jitsi = record("jitsi", "https://meet.example/a")
        let mts = record("mtslink", "https://mts.example/j/1/2")
        guard case .olcrtc(let j) = jitsi.details, case .olcrtc(let m) = mts.details else { return XCTFail() }
        let params = try XCTUnwrap(ServerBundle.params(protocols: [j, m], bond: nil))
        let bundle = ConnectionRecord(name: "srv", details: .olcrtc(params))
        let records = [bundle, jitsi, mts]
        let covered = ServerBundle.coveredIDs(in: records)
        XCTAssertEqual(covered, [jitsi.id, mts.id])
        XCTAssertEqual(health.automaticSweepCandidates(records, keep: [], covered: covered, stopped: []).map(\.id),
                       [bundle.id], "the whole-server record speaks for its rooms")
        XCTAssertEqual(health.automaticSweepCandidates(records, keep: [], covered: covered,
                                                       stopped: [bundle.id, jitsi.id]).map(\.id),
                       [mts.id], "with its first room stopped, the room that runs is checked itself")
    }
}
