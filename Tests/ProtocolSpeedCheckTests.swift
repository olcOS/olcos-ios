import XCTest
@testable import olcrtc_ios

// The connection check's per-protocol rows: which lane is fastest, how much
// bonding gains over it, and that re-checking keeps what was measured. The
// measuring itself goes through live SOCKS ports and is integration-only.

@MainActor
final class ProtocolSpeedCheckTests: XCTestCase {

    private typealias Row = ProtocolSpeedCheck.Row

    private func row(_ id: Int, _ bytesPerSecond: Double?, _ phase: Row.Phase = .done) -> Row {
        Row(id: id, name: "lane \(id)", phase: phase, pingMs: 90, bytesPerSecond: bytesPerSecond)
    }

    func testTheFastestLaneIsTheFastestFinishedOneAndNeverTheBond() {
        let rows = [row(0, 300_000), row(1, 560_000), row(2, 900_000, .failed),
                    row(ProtocolSpeedCheck.allTogether, 1_500_000)]
        XCTAssertEqual(ProtocolSpeedCheck.fastestLane(rows)?.id, 1)
    }

    func testTheGainComparesTheBondWithTheFastestLane() {
        let rows = [row(0, 300_000), row(1, 500_000), row(ProtocolSpeedCheck.allTogether, 1_250_000)]
        XCTAssertEqual(ProtocolSpeedCheck.gain(rows) ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertNil(ProtocolSpeedCheck.gain(Array(rows.dropLast())), "no bonded row yet")
        XCTAssertNil(ProtocolSpeedCheck.gain([row(ProtocolSpeedCheck.allTogether, 1_250_000)]),
                     "no lane measured yet")
    }

    func testPreparingKeepsTheResultsOfTheSameTargets() {
        let check = ProtocolSpeedCheck()
        check._showForTesting([row(0, 300_000), row(1, 500_000)])
        check.prepare([.init(id: 0, name: "lane 0", port: 1), .init(id: 2, name: "lane 2", port: 3)])
        XCTAssertEqual(check.rows.map(\.id), [0, 2])
        XCTAssertEqual(check.rows.first?.bytesPerSecond, 300_000, "the same lane keeps its result")
        XCTAssertNil(check.rows.last?.bytesPerSecond)
    }
}
