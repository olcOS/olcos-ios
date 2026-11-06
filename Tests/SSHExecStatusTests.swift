import XCTest
@testable import olcrtc_ios

// Every SSH command runs in a subshell with its exit status printed after it,
// so a failing script's own `ERROR:` line reaches the user instead of
// "command failed (1)". The carrier list also reports the core the server
// runs, its commit and the patch series on top, which decides whether the app
// updates it. The SSH runs are integration-only (checked on a VPS on
// 2026-10-10).

final class SSHExecStatusTests: XCTestCase {

    func testTheStatusIsSplitOffTheOutput() {
        let ok = SSHRunner.splitExitStatus("line one\nline two\n\n__OLCOS_EXIT=0\n")
        XCTAssertEqual(ok.output, "line one\nline two\n")
        XCTAssertEqual(ok.status, 0)
        let failed = SSHRunner.splitExitStatus("[*] start\nERROR: container nope not found\n\n__OLCOS_EXIT=1\n")
        XCTAssertEqual(failed.status, 1)
        XCTAssertFalse(failed.output.contains("__OLCOS_EXIT"))
    }

    func testAMissingMarkerMeansTheChannelEndedEarly() {
        let cut = SSHRunner.splitExitStatus("partial output")
        XCTAssertEqual(cut.output, "partial output")
        XCTAssertNil(cut.status)
    }

    func testOnlyTheLastMarkerCounts() {
        let raw = "echo __OLCOS_EXIT=7 from the script\n\n__OLCOS_EXIT=0\n"
        XCTAssertEqual(SSHRunner.splitExitStatus(raw).status, 0)
    }

    func testTheReasonIsTheScriptsOwnWords() {
        XCTAssertEqual(SSHRunner.failureReason("[*] cloning\nERROR: salutejazz is not in this core\n[*] cleanup"),
                       "salutejazz is not in this core")
        XCTAssertEqual(SSHRunner.failureReason("[*] building\n[X] Build failed\n"), "Build failed")
        XCTAssertEqual(SSHRunner.failureReason("something\nthe last words\n"), "the last words")
        XCTAssertNil(SSHRunner.failureReason("\n  \n"))
        XCTAssertEqual(SSHRunner.failureReason("ERROR: " + String(repeating: "x", count: 500))?.count, 300)
    }

    func testTheCoreCommitIsReadOnlyWhenWellFormed() {
        let commit = "403edd409011dd371796260196ecd17630df0fdd"
        XCTAssertEqual(SSHRunner.parseCoreCommit(from: "OLCRTC_CARRIER_END\nOLCRTC_CORE=\(commit)\n"), commit)
        XCTAssertEqual(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=\(commit.uppercased())"), commit)
        XCTAssertNil(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=\n"), "not a git checkout")
        XCTAssertNil(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=fatal: not a git repository"))
        XCTAssertNil(SSHRunner.parseCoreCommit(from: "no such line"))
    }

    func testTheCoreIsItsCommitAndTheSeriesTheServerRecorded() {
        let commit = "403edd409011dd371796260196ecd17630df0fdd"
        let series = String(repeating: "ab", count: 32)
        XCTAssertEqual(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=\(commit)\nOLCRTC_CORE_PATCH=\(series)\n"),
                       "\(commit)+\(series)")
        XCTAssertEqual(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=\(commit)\nOLCRTC_CORE_PATCH=\n"), commit,
                       "a core built without a series")
        XCTAssertEqual(SSHRunner.parseCoreCommit(from: "OLCRTC_CORE=\(commit)\nOLCRTC_CORE_PATCH=cat: no such file\n"),
                       commit)
    }

    /// Under Update the core is one line: the short commit and series.
    func testTheCoreIsShownShort() {
        let commit = String(repeating: "a", count: 40)
        let series = String(repeating: "b", count: 64)
        XCTAssertEqual(SSHRunner.shortCoreIdentity(commit), "aaaaaaa")
        XCTAssertEqual(SSHRunner.shortCoreIdentity(SSHRunner.coreIdentity(commit: commit, series: series)),
                       "aaaaaaa + bbbbbbbb")
    }

    func testTheAppsSeriesIsTheBundledPatch() {
        let id = SSHRunner.corePatchID
        XCTAssertEqual(id.count, 64, "the app carries the Telemost framing series")
        XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        XCTAssertEqual(SSHRunner.expectedCoreIdentity, "\(AppConstants.upstreamCorePin)+\(id)")
    }

    func testOnlyThePinnedCoreWithTheSeriesIsCurrent() {
        XCTAssertEqual(SSHRunner.coreIsCurrent(SSHRunner.expectedCoreIdentity), true)
        XCTAssertEqual(SSHRunner.coreIsCurrent(AppConstants.upstreamCorePin), false,
                       "the bare pin lacks the series, and Telemost does not work without it")
        XCTAssertEqual(SSHRunner.coreIsCurrent("54bd2690000000000000000000000000000000ab"), false)
        XCTAssertNil(SSHRunner.coreIsCurrent(nil))
    }

    func testTheCoreReadIsOneReadOnlyCommand() {
        let script = SSHRunner.coreCommitScript(containerName: "olcrtc-server-abc")
        XCTAssertTrue(script.contains("\"olcrtc-server-abc\""))
        XCTAssertTrue(script.contains("OLCRTC_CORE=$(git -C \"$DEPLOY_DIR\" rev-parse HEAD"))
        XCTAssertTrue(script.contains("OLCRTC_CORE_PATCH=$(cat \"$DEPLOY_DIR/.olcos-core-patch\""))
        XCTAssertFalse(script.contains("podman restart"))
        XCTAssertFalse(script.contains("podman run"))
    }

    @MainActor
    func testTheWatchKeepsOnlyServersOnAnotherCore() {
        let watch = CoreVersionWatch(hosts: ServerHostStore(defaults: UserDefaults(suiteName: "olcos.corewatch")!))
        let (stale, current) = (UUID(), UUID())
        watch.note(hostID: stale, commit: "54bd2690000000000000000000000000000000ab")
        watch.note(hostID: current, commit: SSHRunner.expectedCoreIdentity)
        XCTAssertEqual(watch.staleHostIDs, [stale])
        watch.note(hostID: stale, commit: nil)
        XCTAssertEqual(watch.staleHostIDs, [stale], "an unknown commit changes nothing")
        watch.note(hostID: stale, commit: SSHRunner.expectedCoreIdentity)
        XCTAssertTrue(watch.staleHostIDs.isEmpty, "an update clears the notice")
        UserDefaults(suiteName: "olcos.corewatch")?.removePersistentDomain(forName: "olcos.corewatch")
    }

    func testTheCarrierListReportsTheCore() {
        let script = SSHRunner.carrierListScript(baseContainerName: "olcrtc-server-abc")
        XCTAssertTrue(script.contains("OLCRTC_CORE=$(git -C \"$DEPLOY_DIR\" rev-parse HEAD"))
        XCTAssertTrue(script.contains("OLCRTC_CORE_PATCH=$(cat \"$DEPLOY_DIR/.olcos-core-patch\""))
    }
}
