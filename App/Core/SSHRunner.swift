import CryptoKit
import Foundation
@preconcurrency import Citadel
import NIO

// SSH transport helpers for Provisioner. Pure static functions over Citadel.
// Extracted from Provisioning.swift on 2026-05-16.

// MARK: - SSHRunner (nonisolated)

enum SSHRunner {

    // MARK: Install

    /// Client-side conventions only — srv.sh never reads or references these paths.
    /// The client creates them via the nohup launch pipeline; renaming any path
    /// here requires no change to srv.sh.
    private enum RemotePaths {
        static let script = "/tmp/olcrtc-ios-srv.sh"
        static let log    = "/tmp/olcrtc-install.log"
        static let exit   = "/tmp/olcrtc-install.exit"
        // #314: key-rotation fallback script (see rotateKey below).
        static let rotateScript = "/tmp/olcrtc-ios-rotate-key.sh"
        // #452: sibling-carrier install script (see addCarrier below).
        static let addCarrierScript = "/tmp/olcrtc-ios-add-carrier.sh"
        // scripts/olcrtc-core.patch when the app carries one, applied by
        // srv.sh (OLCRTC_CORE_PATCH) and by updateScript; see
        // corePatchUploadCommand.
        static let corePatch = "/tmp/olcrtc-ios-core.patch"
    }

    private static let installMaxPolls: Int               = 100   // 100 × 15 s = 25 min max
    private static let installPollInterval: TimeInterval  = 15
    private static let sshRetryDelay: TimeInterval        = 4    // pause between SSH connect retries — matches L10n.sshRetryIn4s

    // Connectivity-loss thresholds during the install poll loop.
    //
    // Why both counters? They detect different failure modes:
    //   - sshErrorAbortThreshold catches SSH-layer breakage (auth churn,
    //     port reset by firewall, broken Citadel channel) when the TCP-22
    //     probe might still succeed.
    //   - probeFailureAbortThreshold catches "the VPS dropped off the
    //     network entirely" (power off, ISP block, kernel panic during
    //     apt-get upgrade) — even if our last SSH-attempt error string
    //     looked benign.
    //
    // The values are deliberately small so the user learns about lost
    // connectivity within ~45 s (3 × 15 s) instead of the full 25-minute
    // budget.
    private static let sshErrorAbortThreshold:    Int = 3   // 3 × 15 s ≈ 45 s
    private static let probeIntervalPolls:        Int = 5   // probe every 5 polls (~75 s)
    private static let probeFailureAbortThreshold: Int = 2  // 2 consecutive probes ≈ 150 s of confirmed unreachability
    private static let probeTimeout: TimeInterval = 5       // TCP-22 probe timeout

    /// Coarse classification of SSH-layer errors thrown during the install
    /// poll. We don't have a structured error type from Citadel, so we sniff
    /// the error description for auth-failure markers — those are
    /// unrecoverable and should abort immediately. Everything else is treated
    /// as transient (timeouts, broken pipes, "connection refused" while the
    /// VPS is rebooting mid-apt-get) and counted toward
    /// `sshErrorAbortThreshold` before we give up.
    enum SSHErrorKind: Equatable {
        case auth          // unrecoverable — bad creds / sshd rejected us
        case transient     // retry: timeout, refused, broken pipe, channel closed
    }

    /// Pure helper exposed for tests. Inspects the lowercased error string
    /// for known auth-failure phrases. New unmatched phrases default to
    /// `.transient` so a poll-loop quirk never permanently locks a user out
    /// of installs — they can still hit the 3-in-a-row abort.
    static func classifySSHError(_ error: Error) -> SSHErrorKind {
        let desc = error.localizedDescription.lowercased()
        // Citadel surfaces auth failures with several different wordings
        // depending on the underlying NIOSSH error path; match all of them.
        let authMarkers = [
            "authentication", "auth failed", "permission denied",
            "password", "unable to authenticate", "all authentication methods failed",
        ]
        if authMarkers.contains(where: { desc.contains($0) }) { return .auth }
        return .transient
    }

    /// Coordinates the three install phases: upload → background launch → poll.
    /// #451 was: `password: String` — every SSH entry point now takes SSHSecret.
    static func install(host: ServerHost, secret: SSHSecret,
                        options: InstallOptions,
                        onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        let script = try loadScript()
        await MainActor.run { LogStore.shared.log(.provisioning,
            "✓ srv.sh \(script.count) bytes") }
        try await uploadScript(host: host, secret: secret, script: script, onStep: onStep)
        try await launchBackground(host: host, secret: secret, options: options, onStep: onStep)
        return try await pollUntilDone(host: host, secret: secret, onStep: onStep)
    }

    // boc #314: generalize the srv.sh-only loader so rotate-key.sh ships and
    // loads the same way (bundle resource, source-tree fallback for dev builds).
    // was: loadScript() with the "srv" resource name hardcoded inside.
    /// Phase 1 — loads srv.sh from app bundle, falling back to the source tree
    /// for simulator / development builds. Pure: no network, no async.
    private static func loadScript() throws -> String {
        try loadBundledScript(named: "srv")
    }

    /// Loads `<name>.<ext>` from the app bundle, falling back to the source tree
    /// for simulator / development builds. Pure: no network, no async.
    // `ext` defaults to "sh": the scripts srv.sh / rotate-key.sh load the same way.
    private static func loadBundledScript(named name: String, ext: String = "sh") throws -> String {
        let url: URL? = Bundle.main.url(forResource: name, withExtension: ext)
            ?? {
                let srcFile = URL(fileURLWithPath: #filePath)
                // #314: third delete added — #filePath is App/Core/SSHRunner.swift,
                // so two deletes landed on App/ and the dev-tree fallback never fired.
                let projectRoot = srcFile
                    .deletingLastPathComponent()  // App/Core/
                    .deletingLastPathComponent()  // App/
                    .deletingLastPathComponent()  // project root
                let candidate = projectRoot.appendingPathComponent("scripts/\(name).\(ext)")
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }()
        guard let url, let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProvisionError.parseFailed(
                "\(name).\(ext) not found — rebuild the app (xcodegen + clean build)")
        }
        return script
    }
    // eoc #314

    /// Phase 2 — uploads srv.sh and the core patch series to the VPS via
    /// base64-encoded printf.
    private static func uploadScript(host: ServerHost, secret: SSHSecret,
                                     script: String,
                                     onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.installStep1Upload.localized())
        let b64 = Data(script.utf8).base64EncodedString()
        let uploadPatch = corePatchUploadCommand()
        try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "upload srv.sh",
                command: "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.script)" +
                         " && chmod +x \(RemotePaths.script)")
            _ = try await execute(client: client, label: "upload core patch", command: uploadPatch)
        }
    }

    /// Writes scripts/olcrtc-core.patch — olcOS's patch series for the pinned
    /// core, the same one Mobile.xcframework is built with — to
    /// RemotePaths.corePatch. srv.sh applies it (OLCRTC_CORE_PATCH in
    /// installEnv) and so does updateScript, so a server never runs a core
    /// the app's own copy disagrees with. With no series in the app it REMOVES
    /// the file instead: a copy left in /tmp by an older app would otherwise be
    /// applied to a core it was never written for, and fail the build.
    static func corePatchUploadCommand() -> String {
        guard let patch = try? loadBundledScript(named: "olcrtc-core", ext: "patch"),
              !patch.isEmpty else {
            return "rm -f \(RemotePaths.corePatch)"
        }
        let b64 = Data(patch.utf8).base64EncodedString()
        return "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.corePatch)"
    }

    /// Phase 3 — fires srv.sh under nohup and returns immediately.
    /// The script writes stdout/stderr to RemotePaths.log and its exit code to
    /// RemotePaths.exit; pollUntilDone reads both to track progress.
    private static func launchBackground(host: ServerHost, secret: SSHSecret,
                                         options: InstallOptions,
                                         onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.installStep2Launch.localized())
        let env = installEnv(options)
        // #096: srv.sh accepts a `--no-cache` flag that purges the server's Go cache
        // before building; we run the script with no args, so the cache is always
        // reused and installs/rebuilds stay fast. A future "clean rebuild" option
        // (#109) would append --no-cache here. (Cache location is OLCRTC_CACHE_DIR —
        // see #093.)
        let cmd = "rm -f \(RemotePaths.log) \(RemotePaths.exit); " +
                  "nohup sh -c '\(env) \(RemotePaths.script); echo $? > \(RemotePaths.exit)' " +
                  "> \(RemotePaths.log) 2>&1 & echo LAUNCH_OK"
        try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "launch srv.sh", command: cmd)
        }
    }

    /// Phase 4 — polls RemotePaths.log every 15 s until OLCRTC_URI= appears
    /// or the script exits. Each poll is a short SSH command (<1 s) so the
    /// NIO idle-channel timeout never fires.
    ///
    /// Connectivity-loss handling (invariants):
    ///   1. SSH errors are caught explicitly and classified:
    ///        - `.auth` → throw `.sshConnect` immediately (no point retrying).
    ///        - `.transient` → log, increment `consecutiveSSHErrors`, continue.
    ///      After `sshErrorAbortThreshold` (3) consecutive transient errors,
    ///      we abort with `.sshConnect` so the user learns about the drop
    ///      within ~45 s instead of waiting the full 25-minute timeout.
    ///   2. Every `probeIntervalPolls` (5) iterations we run a short TCP-22
    ///      probe — #462: via `reachabilityProbe`, i.e. direct when there is no
    ///      tunnel and a SOCKS5 CONNECT through it when there is, so the probe
    ///      tests the SAME path the polls use. After `probeFailureAbortThreshold` (2)
    ///      consecutive probe failures (~150 s of confirmed unreachability)
    ///      we abort with `.sshConnect(serverUnreachable_fmt)`.
    ///   3. Any successful SSH poll or successful probe resets BOTH counters.
    private static func pollUntilDone(host: ServerHost, secret: SSHSecret,
                                      onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        let client = CitadelSSHClient(host: host, secret: secret)
        return try await pollLoop(
            sshClient: client,
            host: host,
            onStep: onStep,
            maxPolls: installMaxPolls,
            pollInterval: installPollInterval,
            sleepFn: { secs in try await Task.sleep(for: .seconds(secs)) },
            // #462: follow the SSH route. This call site OVERRODE pollLoop's own
            // default, so leaving it alone would have kept aborting installs on a
            // direct TCP-22 probe during a whitelist window even though every SSH
            // poll was flowing through the tunnel.
            // #462 was: `{ h, port in await NetPing.tcp(host: h, port: UInt16(port), timeout: Self.probeTimeout).success }`
            probeFn: { h, port in
                await SSHRunner.reachabilityProbe(host: h, port: port,
                                                  timeout: Self.probeTimeout).success
            }
        )
    }

    private static func installPhase(from line: String) -> String? {
        let l = line.lowercased()
        if l.contains("installing podman") || l.contains("apt install") { return L10n.installPhaseSystemDeps.localized() }
        if l.contains("cloning") || l.contains("git clone") { return L10n.installPhaseClone.localized() }
        if l.contains("pulling go image") || l.contains("podman pull") { return L10n.installPhasePullImage.localized() }
        if l.contains("go: downloading") || l.contains("go mod tidy") { return L10n.installPhaseDeps.localized() }
        if l.contains("building olcrtc") || l.contains("go build") { return L10n.installPhaseBuild.localized() }
        if l.contains("starting olcrtc") || l.contains("podman run -d") { return L10n.installPhaseStart.localized() }
        return nil
    }

    /// Core install poll loop, extracted for testability.
    ///
    /// All I/O is mediated through `sshClient` (inject `MockSSHClient` in
    /// tests, `CitadelSSHClient` in production). `sleepFn` and `probeFn`
    /// are also injectable so tests run instantly without real sleeps or
    /// network probes.
    ///
    /// `host` is kept as a parameter solely so the probe function has the
    /// host/port strings for log messages; it is NOT used to open connections
    /// — all SSH work goes through `sshClient.execute(command:)`.
    static func pollLoop(
        sshClient: any SSHClientProtocol,
        host: ServerHost,
        onStep: @Sendable @escaping (String) -> Void,
        maxPolls: Int = installMaxPolls,
        pollInterval: TimeInterval = installPollInterval,
        sleepFn:  @Sendable (TimeInterval) async throws -> Void = { secs in try await Task.sleep(for: .seconds(secs)) },
        // boc #462: the default probe follows the SSH route. A direct TCP-22 ping
        // is exactly what a carrier whitelist window kills, so during one it used
        // to abort an install whose SSH commands were still flowing fine through
        // the tunnel. `reachabilityProbe` pings direct when there is no tunnel and
        // opens a one-shot SOCKS5 CONNECT through it when there is. The parameter
        // stays injectable, so `MockSSHClient`-driven tests are unaffected.
        // #462 was: `{ h, port in await NetPing.tcp(host: h, port: UInt16(port)).success }`
        probeFn:  @Sendable (String, Int)  async       -> Bool  = { h, port in
            await SSHRunner.reachabilityProbe(host: h, port: port).success
        }
        // eoc #462
    ) async throws -> InstallResult {
        var consecutiveSSHErrors:    Int = 0
        var consecutiveProbeFailures: Int = 0

        // Byte offset into RemotePaths.log already fetched. Each poll asks the
        // server for `wc -c` of the file plus the slice starting at this
        // offset, so an install that emits ~30 lines doesn't re-transfer those
        // lines on every one of the (up to 100) polls. Without this we pulled
        // the last 32 KiB per poll = ~3.2 MiB per install, and each line was
        // re-persisted into LogStore via execute()'s line-by-line logger
        // (dozens of duplicates per line over the install).
        var currentPhase = L10n.installPhaseWaiting.localized()
        var logOffset: Int = 0
        // Set true once on parse failure of the wc -c probe so we don't spam
        // the log on every subsequent poll if the format is somehow off.
        var loggedParseFallback = false

        for poll in 1...maxPolls {
            try await sleepFn(pollInterval)

            // Periodic TCP-22 reachability probe — catches "VPS dropped off
            // the network" cases that the SSH-error sniffing alone misses.
            if poll % probeIntervalPolls == 0 {
                let probeSuccess = await probeFn(host.host, host.port)
                if probeSuccess {
                    consecutiveProbeFailures = 0
                } else {
                    consecutiveProbeFailures += 1
                    let failures = consecutiveProbeFailures
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "✗ TCP/\(host.port) probe failed (poll \(poll), \(failures)/\(Self.probeFailureAbortThreshold))")
                    }
                    if consecutiveProbeFailures >= probeFailureAbortThreshold {
                        let target = "\(host.host):\(host.port)"
                        let msg = L10n.serverUnreachable_fmt.formatted(target)
                        await MainActor.run {
                            LogStore.shared.log(.provisioning,
                                "✗ Aborting install: lost connectivity to \(target) mid-install")
                        }
                        throw ProvisionError.sshConnect(msg)
                    }
                }
            }

            let output: String
            do {
                // Stream only the bytes after logOffset. The leading `wc -c`
                // reports the current file size so we can advance the offset
                // for the next poll. `head -c 32768` caps a single response
                // even when a burst of output landed between polls.
                let offset = logOffset
                let pollCmd =
                    "wc -c < \(RemotePaths.log) 2>/dev/null; " +
                    "echo '---NEW---'; " +
                    "tail -c +\(offset + 1) \(RemotePaths.log) 2>/dev/null | head -c 32768; " +
                    "echo '---STATUS---'; " +
                    "[ -f \(RemotePaths.exit) ] && echo DONE || echo RUNNING"
                output = try await sshClient.execute(command: pollCmd)
                // Successful SSH round-trip — reset both connectivity counters.
                consecutiveSSHErrors    = 0
                consecutiveProbeFailures = 0
            } catch let error {
                let kind = classifySSHError(error)
                let desc = error.localizedDescription
                switch kind {
                case .auth:
                    // Unrecoverable — credentials changed or sshd rejected us.
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "✗ SSH auth failure during poll \(poll): \(desc)")
                    }
                    throw ProvisionError.sshConnect(desc)
                case .transient:
                    consecutiveSSHErrors += 1
                    let errors = consecutiveSSHErrors
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "⚠ SSH error during poll \(poll) (\(errors)/\(Self.sshErrorAbortThreshold)): \(desc)")
                    }
                    if consecutiveSSHErrors >= sshErrorAbortThreshold {
                        await MainActor.run {
                            LogStore.shared.log(.provisioning,
                                "✗ Aborting install: \(sshErrorAbortThreshold) consecutive SSH errors")
                        }
                        throw ProvisionError.sshConnect(desc)
                    }
                    onStep(L10n.installStep3PollRetry_fmt.formatted(poll))
                    continue
                }
            }

            guard !output.isEmpty else {
                onStep(L10n.installStep3PollRetry_fmt.formatted(poll)); continue
            }

            let parsed = parsePollPayload(output)
            let logTail = parsed.body
            let isDone  = parsed.isDone

            // Advance the offset for the next poll. If wc -c failed to parse
            // (newSize == nil), log the fallback once and don't advance the
            // offset — the next poll will receive the full tail-c-style body
            // because we asked for "tail -c +1" which is "everything from
            // byte 1" = the entire file. Functionally identical to the
            // pre-change behavior, just on the rare degenerate path.
            if let newSize = parsed.newSize {
                // Defensive: if the file shrank (rotated, server rebooted,
                // temp file wiped) we still trust the server's reported size
                // and just reset to it. `tail -c +(N+1)` against a file
                // shorter than N silently produces empty output, which is
                // harmless — we just won't re-see lines that vanished.
                // `max(0,…)` defends against an unexpected negative (wc -c
                // never returns negative, but Int(parsedString) on a stray
                // "-1" or similar would round-trip; cheap to defend).
                logOffset = max(0, newSize)
            } else if !loggedParseFallback {
                loggedParseFallback = true
                await MainActor.run {
                    LogStore.shared.log(.provisioning,
                        "⚠ poll wc -c parse failed; falling back to full-tail mode for the rest of the install")
                }
            }

            if let lastLine = logTail.split(separator: "\n")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                for line in logTail.split(separator: "\n") {
                    if let phase = installPhase(from: String(line)) {
                        currentPhase = phase
                    }
                }
                onStep("[3/3] \(currentPhase)\n\(String(lastLine.prefix(60)))")
            }

            // The new-tail-only stream usually won't contain OLCRTC_URI lines
            // (they're emitted near the end of srv.sh once) so this is mostly
            // a fast-path for the very poll in which they appear. The
            // post-`isDone` full-log read below is the real safety net.
            if let result = parseInstallResult(from: logTail) { return result }

            // Script exited without emitting URI in the tail — read the full log.
            if isDone {
                // Re-use the same sshClient for the full-log read so tests can
                // supply a second canned response for the "cat" command.
                let fullLog = (try? await sshClient.execute(
                    command: "cat \(RemotePaths.log) 2>/dev/null")) ?? logTail
                if let result = parseInstallResult(from: fullLog) { return result }
                // The user gets one line and a pointer to Logs; the tail goes there.
                let tail20 = fullLog.split(separator: "\n").suffix(20).joined(separator: "\n")
                await MainActor.run {
                    LogStore.shared.log(.provisioning, "✗ install: no OLCRTC_URI in the log — last lines:\n\(tail20)")
                }
                throw ProvisionError.parseFailed(
                    L10n.installFailedNoURI_fmt.formatted(installFailureReason(fullLog)))
            }
        }
        throw ProvisionError.parseFailed(L10n.installTimeout25min.localized())
    }

    /// Pure helper exposed for tests. Splits the `poll N` SSH response into
    /// its three parts:
    ///   `<wc-c-line>\n---NEW---\n<new-tail-body>\n---STATUS---\n<DONE|RUNNING>`
    ///
    /// Returns:
    ///   - `newSize`: parsed `wc -c` byte count, or `nil` if the line was
    ///     empty / non-numeric (e.g. log file not yet created on first poll,
    ///     or some `wc` quirk on a non-GNU coreutils install).
    ///   - `body`: the new-tail slice (everything between `---NEW---\n` and
    ///     `\n---STATUS---\n`). If markers are missing — e.g. older server
    ///     produced a different shape — we fall back to "everything before
    ///     `---STATUS---`" so the parser still finds OLCRTC_URI=… lines.
    ///   - `isDone`: trailing token is exactly "DONE" (trimmed).
    static func parsePollPayload(_ output: String) -> (newSize: Int?, body: String, isDone: Bool) {
        // Status marker first — used to split the trailing DONE/RUNNING off.
        let statusParts = output.components(separatedBy: "\n---STATUS---\n")
        let beforeStatus = statusParts.first ?? ""
        let isDone = (statusParts.count > 1
                        ? statusParts.last ?? ""
                        : "").trimmingCharacters(in: .whitespacesAndNewlines) == "DONE"

        // Split out the wc -c header from the body via the ---NEW--- marker.
        // Use the first occurrence so a literal "---NEW---" inside the log
        // body (extremely unlikely but cheap to be defensive about) doesn't
        // shift the split.
        if let range = beforeStatus.range(of: "\n---NEW---\n") {
            let header = String(beforeStatus[..<range.lowerBound])
            let body   = String(beforeStatus[range.upperBound...])
            let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSize = Int(trimmedHeader)
            return (newSize, body, isDone)
        }
        // Marker missing entirely — treat the whole pre-status chunk as body,
        // size unknown. Backward-compatible with the pre-change command shape.
        return (nil, beforeStatus, isDone)
    }

    /// Extracts OLCRTC_URI + OLCRTC_CONTAINER from script output.
    /// Returns nil when either key is absent (install still in progress).
    static func parseInstallResult(from output: String) -> InstallResult? {
        // Single-pass extract — walks the log once for both keys instead of
        // twice. Bounded log (final URI + container live within the last few
        // KiB), so the win is microseconds; we do it because each poll's
        // full-log fallback (the `isDone` branch) can be much larger than the
        // incremental tail. Keep parseInstallResult cheap so the fallback
        // path can run unconditionally.
        let values = extract(keys: ["OLCRTC_URI", "OLCRTC_CONTAINER"], from: output)
        guard let uri       = values["OLCRTC_URI"],
              let container = values["OLCRTC_CONTAINER"]
        else { return nil }
        return InstallResult(uri: uri, containerName: container)
    }

    /// Builds the env var prefix for the non-interactive script invocation.
    /// Variable names must match the boc olcrtc-ios patches in scripts/srv.sh.
    static func installEnv(_ options: InstallOptions) -> String {
        var vars: [String] = [
            "OLCRTC_CARRIER=\(shellSafe(options.carrier))",
            "OLCRTC_TRANSPORT=\(shellSafe(options.transport))",
            // No client-id: upstream dropped it from the URI scheme and srv.sh
            // (the YAML config has no client-id field). ConnectionRecord.clientID
            // defaults to "default" when the parsed URI omits the %clientID part.
            "OLCRTC_DNS=\(shellSafe(DNSChoice.forServer(SettingsStore.shared.dnsServer)))",
            // Marker for iOS-app installs. Survives into the URI as
            // `$auto-provisioned` (the mimo / sub-config-name field) and
            // surfaces in ConnectionRecord, which lets us spot iOS-installed
            // VPSes vs ones provisioned manually via curl|sh. The server-side
            // default in scripts/srv.sh matches this literal, but we set it
            // explicitly so the marker is unconditional — even if a future
            // server-script revision drops the default we still produce the
            // marker. If you rename, update both sides together.
            // cross-ref: scripts/srv.sh, the `sub_configname=` boc block.
            "OLCRTC_CONFIG_NAME=auto-provisioned",
            // #442: pin the server core to the SAME upstream commit the shipped
            // Mobile.xcframework is built from. The olcrtc wire protocol is not
            // backward-compatible across upstream's #140 overhaul and there is no
            // version negotiation, so a server built from a different commit fails
            // every tunnel right after the handshake. scripts/srv.sh reads
            // OLCRTC_PIN and fetches that commit instead of cloning a moving
            // branch. Keep AppConstants.upstreamCorePin == the .gitmodules pin.
            "OLCRTC_PIN=\(AppConstants.upstreamCorePin)",
            // The patch series uploadScript put on the server; srv.sh applies
            // it on top of OLCRTC_PIN before building.
            "OLCRTC_CORE_PATCH=\(RemotePaths.corePatch)",
            // The series' id, which srv.sh records next to the core once it
            // applied the series: the pin alone does not tell a patched core
            // from a bare one (coreCommitScript reads it back).
            "OLCRTC_CORE_PATCH_ID=\(corePatchID)",
        ]
        if !options.roomID.isEmpty {
            // MTS Link: the server joins by the plain link plus an ICE hint —
            // the typed one, else `?ice=both` (MTSLinkRoom.serverRoom). The
            // record on the phone keeps what was typed.
            let room = options.carrier == "mtslink"
                ? (MTSLinkRoom.serverRoom(options.roomID) ?? options.roomID)
                : options.roomID
            vars.append("OLCRTC_ROOM_ID=\(shellSafe(room))")
        }
        if options.carrier == "jitsi" {
            // Base Jitsi server (#256): user-chosen in the install sheet, pre-filled
            // from AppConstants.defaultJitsiBaseURL and guaranteed non-empty there.
            // srv.sh prefixes a short room name with this, or uses it for the
            // auto-generated room; a full http(s) URL in OLCRTC_ROOM_ID is used
            // verbatim and this base is ignored.
            vars.append("OLCRTC_JITSI_URL=\(shellSafe(options.jitsiBaseURL))")
        }
        if options.transport == "vp8channel" {
            let vp8 = Vp8Tuning.effective(carriers: [options.carrier],
                                          fps: SettingsStore.shared.vp8FPS,
                                          batch: SettingsStore.shared.vp8BatchSize)
            vars.append("OLCRTC_VP8_FPS=\(vp8.fps)")
            vars.append("OLCRTC_VP8_BATCH=\(vp8.batch)")
        }
        if options.transport == "seichannel" {
            vars.append("OLCRTC_SEI_FPS=\(options.seiFPS)")
            vars.append("OLCRTC_SEI_BATCH=\(options.seiBatch)")
            vars.append("OLCRTC_SEI_FRAG=\(options.seiFrag)")
            vars.append("OLCRTC_SEI_ACK=\(options.seiACK)")
        }
        // NOTE: videochannel uses OLCRTC_VIDEO_{W,H,FPS,BITRATE,HW,CODEC,
        // QR_RECOVERY,QR_SIZE,TILE_MODULE,TILE_RS} per scripts/srv.sh.
        // #097 was: "Server defaults apply — not yet exposed in the UI."
        // #097 decision: deliberately never exposed — ten niche knobs for a
        // works-but-slow transport aren't worth the UI sprawl; the install
        // sheet's videochannel footer tells the user server defaults apply.
        //
        // #093: OLCRTC_CACHE_DIR is another server-side knob (scripts/srv.sh:
        // CACHE_DIR="${OLCRTC_CACHE_DIR:-$HOME/.cache/olcrtc}") that relocates the Go
        // module/build cache. We deliberately don't set it — the default
        // $HOME/.cache/olcrtc persists across VPS reboots and is correct for the
        // single-purpose VPSes we provision. Surface it in Settings only if a custom
        // cache location is ever needed. (Cache *purging* is --no-cache — see #096.)
        return vars.joined(separator: " ")
    }

    /// Strips shell metacharacters and whitespace from values embedded as
    /// `KEY=VALUE` env vars in the launch command.
    ///
    /// Whitespace is critical: env var assignments are space-separated, so a
    /// value containing a space would split into a new positional argument and
    /// the rest of the value would be interpreted as a command. Telemost room
    /// IDs in particular often arrive copy-pasted in display form with spaces
    /// like "3528 5410 1234" — we strip those down to "352854101234".
    static func shellSafe(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            // > 0x20 (not >= 0x20) drops space + all control chars.
            ($0.value > 0x20 && $0.value < 0x7F) &&
            $0 != "\"" && $0 != "\\" && $0 != "`" && $0 != "$" && $0 != "'" &&
            $0 != ";"  && $0 != "&"  && $0 != "|" && $0 != "<" && $0 != ">" &&
            $0 != "("  && $0 != ")"
        })
    }

    // ── old Phase-based install removed ──
    // The multi-phase approach (apt / clone / build / run) is now handled
    // entirely by scripts/srv.sh. See that file and scripts/parity_check.py
    // for how we stay in sync with upstream olcrtc-upstream/script/srv.sh.


    static func uninstall(host: ServerHost, secret: SSHSecret, containerName: String?,
                           onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningUninstalling.localized())
        try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "uninstall",
                                  command: uninstallScript(containerName: containerName))
        }
    }

    // MARK: Update script

    /// Shell script that re-syncs the pinned server core and rebuilds the
    /// binary, then restarts the container — without re-running apt-get.
    ///
    /// Strategy: find the container by name (or the first olcrtc-server-*
    /// container when no name is recorded), fetch the pinned commit into the
    /// bind-mounted deploy dir with HOST git, rebuild in a detached builder
    /// container (the same `podman run --rm … go build` scripts/srv.sh uses),
    /// then `podman restart` so the new binary is picked up.
    static func updateScript(containerName: String?) -> String {
        let target = containerName ?? containerNamePrefix
        return #"""
        set -e
        if podman ps -a --format '{{.Names}}' | grep -q '^\#(target)$' 2>/dev/null; then
            CNAME="\#(target)"
        else
            CNAME=$(podman ps -aq --filter 'name=\#(containerNamePrefix)' --format '{{.Names}}' | head -1)
        fi
        if [ -z "$CNAME" ]; then
            echo "ERROR: no olcrtc container found" >&2; exit 1
        fi
        echo "UPDATE: container=$CNAME"
        # #451: machine-readable copy of the resolved name — when no container
        # name was recorded the sweep above may pick one, and ServersView.update
        # adopts this into host.lastContainerName (mirrors #302's auto-detect).
        echo "OLCRTC_UPDATE_CONTAINER=$CNAME"
        # #442: "Update Binary" = re-sync the server core to the commit the app's
        # Mobile.xcframework is built from, then rebuild. git runs on the HOST
        # against the bind-mounted deploy dir — the olcrtc image (golang:alpine)
        # ships go but NOT git, so `git` inside the container fails "git: not found"
        # (this is the same host-git / builder-container split scripts/srv.sh
        # already uses). Fetching a fixed SHA (not `git pull` on a moving branch)
        # is what stops the version drift that broke every server, and it also
        # migrates an old master-tracking install onto the pin on the next update.
        # #442 was: exec'ing `cd /app && git pull --ff-only` inside "$CNAME"
        #   — ran git in the container (absent) AND tracked master (the drift).
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "$CNAME")
        if [ -z "$DEPLOY_DIR" ] || [ ! -d "$DEPLOY_DIR/.git" ]; then
            echo "ERROR: git deploy dir not found for $CNAME (dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        # The tracked sources still carry the previous build's core patches:
        # restore them so the checkout cannot trip over them (server*.yaml and
        # the binary are untracked and stay). The core moved to the fork that
        # continues the archived upstream; the pinned commit exists only there,
        # so an older install's origin is pointed at it first. Then apply the
        # series update() has just uploaded, if the app carries one (the one
        # this app's Mobile.xcframework is built with, scripts/olcrtc-core.patch).
        git -C "$DEPLOY_DIR" reset -q --hard
        git -C "$DEPLOY_DIR" remote set-url origin \#(AppConstants.coreRepositoryURL)
        git -C "$DEPLOY_DIR" fetch --depth 1 origin \#(AppConstants.upstreamCorePin)
        git -C "$DEPLOY_DIR" checkout -q FETCH_HEAD
        if [ -s \#(RemotePaths.corePatch) ]; then
            git -C "$DEPLOY_DIR" apply \#(RemotePaths.corePatch) || {
                echo "ERROR: the olcOS core patch series does not apply to the pinned core" >&2; exit 1
            }
            printf '%s\n' '\#(corePatchID)' > "$DEPLOY_DIR/.olcos-core-patch"
        else
            rm -f "$DEPLOY_DIR/.olcos-core-patch"
        fi
        # #451 was: exec'ing the go build inside "$CNAME" — an exec session
        # needs a RUNNING container ("can only create exec sessions on running
        # containers"), but the menu offers Update for stopped containers too,
        # so updating a stopped server died with an opaque exec failure. Build
        # in a detached builder container instead — the exact scripts/srv.sh
        # build line (image, flags, ./cmd/olcrtc entrypoint), with the same
        # ~/.cache/olcrtc mounts so updates reuse the module/build cache. The
        # final `podman restart` also STARTS a stopped container, so an update
        # doubles as a start with a fresh binary.
        CACHE_DIR="$HOME/.cache/olcrtc"
        mkdir -p "$CACHE_DIR/gomod" "$CACHE_DIR/gobuild"
        podman run --rm \
            --network host \
            -v "$DEPLOY_DIR":/app:Z \
            -v "$CACHE_DIR/gomod":/go/pkg/mod:Z \
            -v "$CACHE_DIR/gobuild":/root/.cache/go-build:Z \
            -w /app \
            \#(AppConstants.serverGoImage) \
            sh -c "go mod download && go build -trimpath -ldflags='-s -w' -o olcrtc ./cmd/olcrtc"
        # Containers from older installs run with `--restart unless-stopped`,
        # which podman-restart.service does not start after a reboot (it
        # starts restart-policy=always only), and podman 4.9 cannot change the
        # policy in place. Recreate each one from its own inspect data — same
        # name, deploy dir, image and command — with `always`, keeping it
        # running or stopped as it was. The old container is renamed aside
        # first and put back if the new one cannot be created.
        recreate_always() {
            c="$1"
            policy=$(podman inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null) || return 0
            [ "$policy" = "always" ] && return 0
            cmd=$(podman inspect --format '{{index .Config.Cmd 2}}' "$c" 2>/dev/null) || return 0
            case "$cmd" in
                "./olcrtc server"*.yaml) ;;
                *) echo "WARN: $c runs '$cmd'; its restart policy is left as is"; return 0 ;;
            esac
            dir=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "$c") || return 0
            img=$(podman inspect --format '{{.ImageName}}' "$c") || return 0
            running=$(podman inspect --format '{{.State.Running}}' "$c") || return 0
            aside="olcos-recreate-$$"
            podman stop -t 3 "$c" >/dev/null 2>&1 || true
            podman rename "$c" "$aside" || return 0
            if podman create --name "$c" --network host --restart always \
                    -v "$dir":/app:Z -w /app "$img" sh -c "$cmd" >/dev/null; then
                podman rm -f "$aside" >/dev/null || true
                echo "RECREATED: $c --restart always"
            else
                podman rename "$aside" "$c" || true
                echo "WARN: $c could not be recreated with --restart always; kept as it was"
            fi
            if [ "$running" = "true" ]; then podman start "$c" >/dev/null || true; fi
        }
        for name in "$CNAME" $(podman ps -a --format '{{.Names}}' | grep "^${CNAME}-" || true); do
            recreate_always "$name"
        done
        systemctl enable podman-restart.service >/dev/null 2>&1 || true
        podman restart "$CNAME"
        # #469: every `<base>-<carrier>` sibling maps the SAME ./olcrtc from the
        # shared deploy dir. The file was replaced above, but a running process
        # keeps the old inode — without a restart the siblings kept speaking the
        # previous build's protocol after the primary had moved on.
        # #481 was: podman ps -a included deliberately stopped siblings.
        # #481: only running siblings need to pick up the new binary now.
        for c in $(podman ps --format '{{.Names}}' | grep "^${CNAME}-" 2>/dev/null); do
            podman restart "$c" >/dev/null 2>&1 || true
        done
        echo "OLCRTC_UPDATED=ok"
        """#
    }

    /// #451: returns the container name the script resolved (the recorded one,
    /// or the first olcrtc-server-* found by the no-name sweep) so the caller
    /// can adopt it into `host.lastContainerName`; nil only if the script
    /// output lost the OLCRTC_UPDATE_CONTAINER line.
    @discardableResult
    static func update(host: ServerHost, secret: SSHSecret, containerName: String?,
                       onStep: @Sendable @escaping (String) -> Void) async throws -> String? {
        onStep(L10n.provisioningUpdating.localized())
        let uploadPatch = corePatchUploadCommand()
        // Through the agent one request may not outlive a core build: run the
        // update detached and follow its log, the way the Android app does.
        if case .agent = secret {
            return try await detachedUpdate(host: host, secret: secret, containerName: containerName,
                                            uploadPatch: uploadPatch, onStep: onStep)
        }
        let output = try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "upload core patch", command: uploadPatch)
            return try await execute(client: client, label: "update",
                                     command: updateScript(containerName: containerName))
        }
        return extract(key: "OLCRTC_UPDATE_CONTAINER", from: output)
    }

    private static let updateRemoteScript = "/tmp/olcos-update.sh"
    private static let updateRemoteLog    = "/tmp/olcos-update.log"
    private static let updateRemoteExit   = "/tmp/olcos-update.exit"

    /// The update as a background job on the server: the script and the
    /// patch go up, `nohup` runs it, and the log's tail is read every few
    /// seconds until the exit file appears (at most half an hour).
    private static func detachedUpdate(host: ServerHost, secret: SSHSecret, containerName: String?,
                                       uploadPatch: String,
                                       onStep: @Sendable @escaping (String) -> Void) async throws -> String? {
        let scriptB64 = Data(updateScript(containerName: containerName).utf8).base64EncodedString()
        let launch = [
            "printf '%s' '\(scriptB64)' | base64 -d > \(updateRemoteScript)",
            uploadPatch,
            "rm -f \(updateRemoteExit) \(updateRemoteLog)",
            "nohup sh -c 'bash \(updateRemoteScript); echo $? > \(updateRemoteExit)' > \(updateRemoteLog) 2>&1 &",
            "echo OLCOS_UPDATE_STARTED=ok",
        ].joined(separator: "\n")
        let started = try await _withConnection(host: host, secret: secret) { client in
            try await execute(client: client, label: "start update", command: launch)
        }
        guard extract(key: "OLCOS_UPDATE_STARTED", from: started) == "ok" else {
            throw ProvisionError.sshCommand(lastErrorLine(started) ?? "update: could not start")
        }
        let poll = "tail -c 6000 \(updateRemoteLog) 2>/dev/null; if [ -f \(updateRemoteExit) ]; then echo \"OLCOS_UPDATE_EXIT=$(cat \(updateRemoteExit))\"; fi"
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let out = try await _withConnection(host: host, secret: secret) { client in
                try await _execute(client: client, label: "update progress", command: poll, logBody: false)
            }
            let log = out.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("OLCOS_UPDATE_EXIT=") }.joined(separator: "\n")
            if let last = log.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                onStep(String(last.prefix(120)))
            }
            guard let exit = extract(key: "OLCOS_UPDATE_EXIT", from: out) else { continue }
            await MainActor.run {
                for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
                    LogStore.shared.log(.provisioning, "    \(line)")
                }
            }
            if exit == "0" { return extract(key: "OLCRTC_UPDATE_CONTAINER", from: log) }
            throw ProvisionError.sshCommand(lastErrorLine(log) ?? "update: exit \(exit)")
        }
        throw ProvisionError.sshCommand("update: no result after thirty minutes")
    }

    /// The last `ERROR:` / `[X]` line of a script's output, or its last line.
    private static func lastErrorLine(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let err = lines.last(where: { $0.hasPrefix("ERROR:") || $0.hasPrefix("[X]") }) { return String(err.prefix(300)) }
        return lines.last.map { String($0.prefix(300)) }
    }

    // MARK: Scan for existing olcrtc containers

    /// Lists all olcrtc-server-* containers (running or stopped) and their args.
    /// Output per line: <name>\t<status>\t<cmd>
    static func scanContainersScript() -> String {
        """
        podman ps -a --filter 'name=olcrtc-server-' \
            --format '{{.Names}}\t{{.Status}}\t{{join .Command " "}}' 2>/dev/null || true
        """
    }

    struct VPSStats: Sendable, Equatable {
        let disk: String    // e.g. "14G/20G"
        let ram: String     // e.g. "241M/2048M"
        let uptime: String  // e.g. "3 days, 4:22"
    }

    struct FoundContainer: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let status: ContainerStatus
        let carrier: String
        let transport: String
        let roomID: String
    }

    static func parseScannedContainers(from output: String) -> [FoundContainer] {
        output.components(separatedBy: "\n")
            .compactMap { line -> FoundContainer? in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("olcrtc-server-") else { return nil }
                let statusStr = parts[1].trimmingCharacters(in: .whitespaces)
                let cmd = parts.count >= 3 ? parts[2] : ""
                let status = ContainerStatus.parse(from: statusStr)
                // Extract args from cmd: olcrtc -mode srv -carrier X -id Y -transport Z ...
                func arg(_ flag: String) -> String {
                    let pattern = " \(flag) "
                    guard let r = cmd.range(of: pattern) else { return "" }
                    let after = String(cmd[r.upperBound...])
                    return String(after.prefix(while: { !$0.isWhitespace }))
                }
                return FoundContainer(
                    name: name, status: status,
                    carrier:   arg("-carrier"),
                    transport: arg("-transport"),
                    roomID:    arg("-id")
                )
            }
    }

    static func startScript(containerName: String) -> String {
        let safe = shellSafe(containerName)
        // Recreate the bind-mount source dir if it was wiped (e.g. /tmp cleared on VPS reboot).
        // Uses `podman inspect` to find the actual host path rather than hard-coding /tmp.
        // Exit 1 on failure so _execute throws and the UI shows an error instead of "Done".
        return """
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "\(safe)" 2>/dev/null)
        [ -n "$DEPLOY_DIR" ] && mkdir -p "$DEPLOY_DIR"
        if podman start "\(safe)" 2>&1; then
            echo OLCRTC_STARTED=ok
        else
            echo OLCRTC_STARTED=error
            exit 1
        fi
        """
    }

    static func start(host: ServerHost, secret: SSHSecret, containerName: String,
                      onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningStarting.localized())
        try await _withConnection(host: host, secret: secret) { client in
            _ = try await _execute(client: client, label: "start", command: startScript(containerName: containerName))
        }
    }

    static func stopScript(containerName: String) -> String {
        let safe = shellSafe(containerName)
        // Exit 1 on failure so _execute throws and the UI shows an error.
        // boc #469: the card's button says "Stop server", and since #452 a server
        // is the primary PLUS every `<base>-<carrier>` sibling. Stopping only the
        // primary left the other protocols serving while the card read
        // "Server stopped". Siblings are best-effort: a missing one is not an
        // error, the primary's result decides the exit code.
        return """
        for c in $(podman ps --format '{{.Names}}' | grep '^\(safe)-' 2>/dev/null); do
            podman stop "$c" 2>&1 || true
        done
        if podman stop "\(safe)" 2>&1; then
            echo OLCRTC_STOPPED=ok
        else
            echo OLCRTC_STOPPED=error
            exit 1
        fi
        """
        // eoc #469
    }

    static func stop(host: ServerHost, secret: SSHSecret, containerName: String,
                     onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningStopping.localized())
        try await _withConnection(host: host, secret: secret) { client in
            _ = try await _execute(client: client, label: "stop", command: stopScript(containerName: containerName))
        }
    }

    // MARK: #452 — Multi-carrier (sibling protocol containers on one VPS)
    //
    // One VPS can run several olcrtc protocols simultaneously: the primary
    // install (scripts/srv.sh → server.yaml → container olcrtc-server-<id>)
    // plus sibling containers named <base>-<carrier> that share the SAME
    // deploy dir / built binary / encryption key and each read their own
    // server-<carrier>.yaml. scripts/add-carrier.sh creates them (uploaded
    // over the same base64-printf channel as rotate-key.sh); the helpers
    // below name, list, and remove them.

    /// Config file name for a sibling carrier ("server-jitsi.yaml").
    /// The primary config stays `server.yaml`.
    static func carrierYAMLFile(_ carrier: String) -> String {
        "server-\(carrier).yaml"
    }

    /// Container name for a sibling carrier — the primary container's name
    /// plus a carrier suffix ("olcrtc-server-abc-jitsi"). Keeps the
    /// `olcrtc-server-` prefix, so the container scan and the uninstall sweep
    /// see siblings without changes.
    static func siblingContainerName(base: String, carrier: String) -> String {
        "\(base)-\(carrier)"
    }

    /// One deployed carrier config on a host, parsed from `carrierListScript`
    /// output. `isPrimary` marks the srv.sh-installed server.yaml entry — the
    /// one whose container anchors the deploy dir (siblings resolve it via
    /// `podman inspect` on that name).
    struct CarrierInfo: Identifiable, Equatable, Sendable {
        var id: String { container }
        let file: String          // "server.yaml" | "server-<carrier>.yaml"
        let provider: String      // auth.provider from the yaml
        let transport: String     // net.transport from the yaml
        let room: String          // room.id from the yaml
        let container: String     // derived container name
        let status: ContainerStatus
        let isPrimary: Bool

        /// An extra room of a carrier (add-carrier.sh `OLCRTC_LANE`):
        /// `server-<carrier>-<n>.yaml` → n. nil for the carrier's own row.
        var lane: Int? { SSHRunner.laneNumber(file: file, provider: provider) }
    }

    /// The lane number of a config file, when it is one: `server-jitsi-2.yaml`
    /// for provider `jitsi` → 2. Matched against the file's own provider so a
    /// carrier's row is never mistaken for a lane.
    static func laneNumber(file: String, provider: String) -> Int? {
        let prefix = "server-\(provider)-", suffix = ".yaml"
        guard !provider.isEmpty, file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        let middle = file.dropFirst(prefix.count).dropLast(suffix.count)
        guard let n = Int(middle), (2...8).contains(n) else { return nil }
        return n
    }

    /// Carrier rows and the extra rooms (lanes) beside them, apart: the card
    /// lists carriers, and each carrier's lanes become its connection's
    /// `extraRooms`.
    static func splitLanes(_ rows: [CarrierInfo]) -> (carriers: [CarrierInfo], lanes: [CarrierInfo]) {
        (rows.filter { $0.lane == nil }, rows.filter { $0.lane != nil })
    }

    /// The extra rooms of `carrier` in lane order.
    static func laneRooms(_ lanes: [CarrierInfo], carrier: String) -> [String] {
        lanes.filter { $0.provider == carrier }
            .sorted { ($0.lane ?? 0) < ($1.lane ?? 0) }
            .map(\.room)
    }

    /// Env prefix for scripts/add-carrier.sh. Mirrors `installEnv` minus the
    /// build-time vars (no OLCRTC_PIN — a sibling reuses the already-built
    /// binary) plus OLCRTC_BASE_CONTAINER (the primary container whose bind
    /// mount locates the deploy dir). Var names must match the $OLCRTC_*
    /// reads in scripts/add-carrier.sh
    /// (Tests/ServerScriptParityTests.testEnvVarNamesMatchAddCarrierScript).
    static func addCarrierEnv(_ options: InstallOptions, baseContainer: String, lane: Int? = nil) -> String {
        var vars: [String] = [
            "OLCRTC_BASE_CONTAINER=\(shellSafe(baseContainer))",
            "OLCRTC_CARRIER=\(shellSafe(options.carrier))",
            "OLCRTC_TRANSPORT=\(shellSafe(options.transport))",
            "OLCRTC_DNS=\(shellSafe(DNSChoice.forServer(SettingsStore.shared.dnsServer)))",
            // Same unconditional iOS-install marker as installEnv — see there.
            "OLCRTC_CONFIG_NAME=auto-provisioned",
        ]
        if !options.roomID.isEmpty {
            // Same rule as installEnv: an MTS Link room reaches the server as
            // the plain link plus its ICE hint.
            let room = options.carrier == "mtslink"
                ? (MTSLinkRoom.serverRoom(options.roomID) ?? options.roomID)
                : options.roomID
            vars.append("OLCRTC_ROOM_ID=\(shellSafe(room))")
        }
        if options.carrier == "jitsi" {
            vars.append("OLCRTC_JITSI_URL=\(shellSafe(options.jitsiBaseURL))")
        }
        if options.transport == "vp8channel" {
            let vp8 = Vp8Tuning.effective(carriers: [options.carrier],
                                          fps: SettingsStore.shared.vp8FPS,
                                          batch: SettingsStore.shared.vp8BatchSize)
            vars.append("OLCRTC_VP8_FPS=\(vp8.fps)")
            vars.append("OLCRTC_VP8_BATCH=\(vp8.batch)")
        }
        if options.transport == "seichannel" {
            vars.append("OLCRTC_SEI_FPS=\(options.seiFPS)")
            vars.append("OLCRTC_SEI_BATCH=\(options.seiBatch)")
            vars.append("OLCRTC_SEI_FRAG=\(options.seiFrag)")
            vars.append("OLCRTC_SEI_ACK=\(options.seiACK)")
        }
        if let lane, (2...8).contains(lane) {
            vars.append("OLCRTC_LANE=\(lane)")
        }
        return vars.joined(separator: " ")
    }

    /// Adds a sibling carrier to an installed host: uploads
    /// scripts/add-carrier.sh (same base64-printf channel as rotate-key.sh)
    /// and runs it synchronously — no build happens (the binary is reused),
    /// so the whole op takes seconds and the nohup/poll install pipeline
    /// would be overkill. The script prints the srv.sh result contract
    /// (OLCRTC_URI= / OLCRTC_CONTAINER=) plus OLCRTC_CARRIER_ADDED=ok.
    static func addCarrier(host: ServerHost, secret: SSHSecret,
                           baseContainer: String, options: InstallOptions, lane: Int? = nil,
                           onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        let script = try loadBundledScript(named: "add-carrier")
        await MainActor.run { LogStore.shared.log(.provisioning,
            "✓ add-carrier.sh \(script.count) bytes") }
        onStep(L10n.installStep1Upload.localized())
        let b64 = Data(script.utf8).base64EncodedString()
        let env = addCarrierEnv(options, baseContainer: baseContainer, lane: lane)
        let output = try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "upload add-carrier.sh",
                command: "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.addCarrierScript)" +
                         " && chmod +x \(RemotePaths.addCarrierScript)")
            return try await execute(client: client, label: "add carrier",
                command: "\(env) \(RemotePaths.addCarrierScript)")
        }
        guard extract(key: "OLCRTC_CARRIER_ADDED", from: output) == "ok",
              let result = parseInstallResult(from: output) else {
            throw ProvisionError.sshCommand("add carrier — \(String(output.suffix(300)))")
        }
        return result
    }

    /// Lists every deployed carrier config on the host anchored by the
    /// primary container: server.yaml plus each sibling server-<carrier>.yaml
    /// in the same deploy dir, with the derived container name and its live
    /// status. Read-only. Output per config:
    ///   OLCRTC_CARRIER_BEGIN / FILE= / PROVIDER= / TRANSPORT= / ROOM= /
    ///   CONTAINER= / STATUS= / OLCRTC_CARRIER_END
    static func carrierListScript(baseContainerName: String) -> String {
        let safeCname = shellSafe(baseContainerName)
        return #"""
        set -e
        CNAME="\#(safeCname)"
        if ! podman ps -a --format '{{.Names}}' | grep -q "^${CNAME}$" 2>/dev/null; then
            echo "ERROR: container ${CNAME} not found" >&2; exit 1
        fi
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}")
        if [ -z "$DEPLOY_DIR" ] || [ ! -f "$DEPLOY_DIR/server.yaml" ]; then
            echo "ERROR: server.yaml not found for ${CNAME} (deploy dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        for f in "$DEPLOY_DIR"/server.yaml "$DEPLOY_DIR"/server-*.yaml; do
            [ -f "$f" ] || continue
            BASE_F=$(basename "$f")
            case "$BASE_F" in
                server.yaml)   C="${CNAME}" ;;
                server-*.yaml) SUF="${BASE_F#server-}"; C="${CNAME}-${SUF%.yaml}" ;;
                *) continue ;;
            esac
            STATUS=$(podman ps -a --filter "name=^${C}$" --format '{{.Status}}' 2>/dev/null | head -1)
            [ -n "$STATUS" ] || STATUS="missing"
            echo "OLCRTC_CARRIER_BEGIN"
            echo "FILE=$BASE_F"
            echo "PROVIDER=$(sed -n 's/^  provider: "\(.*\)"$/\1/p' "$f" 2>/dev/null | head -1)"
            echo "TRANSPORT=$(sed -n 's/^  transport: "\(.*\)"$/\1/p' "$f" 2>/dev/null | head -1)"
            echo "ROOM=$(sed -n 's/^  id: "\(.*\)"$/\1/p' "$f" 2>/dev/null | head -1)"
            echo "CONTAINER=$C"
            echo "STATUS=$STATUS"
            echo "OLCRTC_CARRIER_END"
        done
        echo "OLCRTC_CORE=$(git -C "$DEPLOY_DIR" rev-parse HEAD 2>/dev/null || true)"
        echo "OLCRTC_CORE_PATCH=$(cat "$DEPLOY_DIR/.olcos-core-patch" 2>/dev/null || true)"
        """#
    }

    /// PURE. The core the server runs, from `carrierListScript`'s or
    /// `coreCommitScript`'s output: its commit, and the patch series it runs
    /// on top (`coreIdentity`); nil when the deploy dir is not a git checkout.
    static func parseCoreCommit(from output: String) -> String? {
        guard let value = extract(key: "OLCRTC_CORE", from: output) else { return nil }
        let commit = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return nil }
        let series = (extract(key: "OLCRTC_CORE_PATCH", from: output) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let recorded = series.count == 64 && series.allSatisfy(\.isHexDigit)
        return coreIdentity(commit: commit, series: recorded ? series : "")
    }

    /// PURE. A core as the app compares it: the commit, followed by
    /// `+<series id>` when a patch series runs on top of it.
    static func coreIdentity(commit: String, series: String) -> String {
        series.isEmpty ? commit : commit + "+" + series
    }

    /// The SHA-256 of the patch series the app carries (scripts/olcrtc-core.patch),
    /// "" without one. A server records it once it applied the series (srv.sh,
    /// updateScript), so a core built without it reads as another core.
    static let corePatchID: String = {
        guard let patch = try? loadBundledScript(named: "olcrtc-core", ext: "patch"), !patch.isEmpty else {
            return ""
        }
        return SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    /// PURE. A core identity short enough for one line: "403edd4 + 884eea8d".
    static func shortCoreIdentity(_ identity: String) -> String {
        let parts = identity.split(separator: "+", maxSplits: 1)
        let commit = parts.first.map { String($0.prefix(7)) } ?? ""
        guard parts.count == 2 else { return commit }
        return "\(commit) + \(parts[1].prefix(8))"
    }

    /// The core this app speaks: the pinned commit and its series.
    static var expectedCoreIdentity: String {
        coreIdentity(commit: AppConstants.upstreamCorePin, series: corePatchID)
    }

    /// Whether a server runs the core this app speaks to. There is no version
    /// negotiation in the protocol: a server on another commit, or on the
    /// same commit without the app's patch series, connects and then loses its
    /// sessions. nil when unknown.
    static func coreIsCurrent(_ commit: String?) -> Bool? {
        commit.map { $0 == expectedCoreIdentity }
    }

    /// Prints `OLCRTC_CORE=<commit>` and the series it records
    /// (`OLCRTC_CORE_PATCH=`) for the install `containerName` belongs to.
    /// Read-only.
    static func coreCommitScript(containerName: String) -> String {
        let cname = shellSafe(containerName)
        return #"""
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "\#(cname)" 2>/dev/null)
        echo "OLCRTC_CORE=$(git -C "$DEPLOY_DIR" rev-parse HEAD 2>/dev/null || true)"
        echo "OLCRTC_CORE_PATCH=$(cat "$DEPLOY_DIR/.olcos-core-patch" 2>/dev/null || true)"
        """#
    }

    /// The core commit a server runs; nil when it cannot be read.
    static func coreCommit(host: ServerHost, secret: SSHSecret, containerName: String) async throws -> String? {
        // A read: on the kept session the server page then uses as well.
        let output = try await SSHReadSessions.shared.read(host: host, secret: secret) { client in
            try await _execute(client: client, label: "core version",
                               command: coreCommitScript(containerName: containerName))
        }
        return parseCoreCommit(from: output)
    }

    /// Parses `carrierListScript` output into `CarrierInfo` rows. Tolerant:
    /// unknown lines are ignored, a block missing FILE/CONTAINER is dropped,
    /// STATUS `missing` maps to `.notFound`. Primary sorts first, siblings
    /// alphabetical by container — a stable order for the host card.
    static func parseCarrierList(from output: String) -> [CarrierInfo] {
        var result: [CarrierInfo] = []
        var block: [String: String]? = nil
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "OLCRTC_CARRIER_BEGIN" { block = [:]; continue }
            if line == "OLCRTC_CARRIER_END" {
                if let b = block,
                   let file = b["FILE"], !file.isEmpty,
                   let container = b["CONTAINER"], !container.isEmpty {
                    let rawStatus = b["STATUS"] ?? ""
                    let status: ContainerStatus = rawStatus == "missing"
                        ? .notFound
                        : ContainerStatus.parse(from: rawStatus)
                    result.append(CarrierInfo(
                        file: file,
                        provider: b["PROVIDER"] ?? "",
                        transport: b["TRANSPORT"] ?? "",
                        room: b["ROOM"] ?? "",
                        container: container,
                        status: status,
                        isPrimary: file == "server.yaml"))
                }
                block = nil
                continue
            }
            guard block != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            block?[key] = String(line[line.index(after: eq)...])
        }
        return result.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.container < $1.container
        }
    }

    /// Removes a sibling carrier: force-removes its container and deletes its
    /// server-<carrier>.yaml from the deploy dir. The target is always
    /// `<base>-<carrier>` — the primary container/config can never be removed
    /// here (that is uninstall's job).
    static func removeCarrierScript(baseContainer: String, carrier: String) -> String {
        // #469: kept for callers that only know the carrier — derives the pair
        // the same way add-carrier.sh named it.
        removeCarrierScript(baseContainer: baseContainer,
                            container: siblingContainerName(base: baseContainer, carrier: carrier),
                            configFile: carrierYAMLFile(carrier))
    }

    /// #469 was: only the carrier-derived form above. A sibling's carrier is
    /// mutable (reconfigure rewrites `provider:` in its own file), after which
    /// `<base>-<provider>` named a container that did not exist — or a DIFFERENT
    /// sibling. The row carries the container and the file it was listed from;
    /// delete exactly those. The primary can never be named here: its file is
    /// `server.yaml`, which this refuses.
    static func removeCarrierScript(baseContainer: String, container: String, configFile: String) -> String {
        let safeCname  = shellSafe(baseContainer)
        let safeTarget = shellSafe(container)
        let safeFile   = shellSafe(configFile)
        return #"""
        CNAME="\#(safeCname)"
        TARGET="\#(safeTarget)"
        FILE="\#(safeFile)"
        if [ "$TARGET" = "$CNAME" ] || [ "$FILE" = "server.yaml" ]; then
            echo "ERROR: refusing to remove the primary protocol (use uninstall)" >&2; exit 1
        fi
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}" 2>/dev/null)
        podman rm -f "${TARGET}" 2>/dev/null || true
        [ -n "$DEPLOY_DIR" ] && rm -f "${DEPLOY_DIR}/${FILE}" 2>/dev/null || true
        echo "OLCRTC_CARRIER_REMOVED=ok"
        """#
    }

    /// One `OLCRTC_SIBLING_URI=<container>|<uri>` line from rotate-key.sh —
    /// the sibling's container name and its post-rotation olcrtc:// URI.
    struct SiblingURI: Equatable, Sendable {
        let container: String
        let uri: String
    }

    /// Parses rotate-key.sh's sibling lines. Splits on the FIRST `|` only —
    /// container names cannot contain `|`, URIs theoretically could.
    static func parseSiblingURIs(from output: String) -> [SiblingURI] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("OLCRTC_SIBLING_URI=") else { return nil }
            let payload = line.dropFirst("OLCRTC_SIBLING_URI=".count)
            guard let bar = payload.firstIndex(of: "|") else { return nil }
            let container = String(payload[payload.startIndex..<bar])
            let uri = String(payload[payload.index(after: bar)...])
            guard !container.isEmpty, !uri.isEmpty else { return nil }
            return SiblingURI(container: container, uri: uri)
        }
    }

    /// rotate-key result: the primary's new URI/container plus every
    /// sibling's. `uri`/`containerName` mirror InstallResult so pre-#452
    /// call sites (ServersView's rotate handler) keep reading `result.uri`
    /// unchanged.
    struct RotateKeyResult: Sendable {
        let primary: InstallResult
        let siblings: [SiblingURI]
        var uri: String { primary.uri }
        var containerName: String { primary.containerName }
    }

    /// Single-call readiness probe. Output format (one per line):
    ///   PODMAN=yes|no
    ///   IMAGE=yes|no
    ///   CONTAINER=<podman ps status line or empty>
    ///   CONTAINER_RC=<exit code of podman ps>
    ///   … DISK/RAM/UPTIME …
    ///   READINESS_END
    ///
    /// The `CONTAINER_RC` line and the `READINESS_END` sentinel exist so the
    /// parser can tell "no such container" from "podman ps failed" or "the
    /// output was cut short". Before them an empty CONTAINER line — whatever
    /// its cause — read as `.imageReady`, and a running server with all its
    /// protocols flashed "Ready to install" until the next refresh.
    static func readinessScript(containerName: String?) -> String {
        let containerCmd: String
        if let name = containerName {
            let safe = shellSafe(name)
            // The status is captured into a variable first so `printf` always
            // ends the CONTAINER line with a newline — a bare pipe into `head`
            // printed nothing on a miss and the next line glued onto it.
            containerCmd = "_c=$(podman ps -a --filter 'name=^\(safe)$' --format '{{.Status}}' 2>/dev/null); _rc=$?; " +
                "printf 'CONTAINER=%s\\n' \"$(printf '%s\\n' \"$_c\" | head -1)\"; printf 'CONTAINER_RC=%s\\n' \"$_rc\""
        } else {
            containerCmd = "printf 'CONTAINER=\\n'; printf 'CONTAINER_RC=0\\n'"
        }
        return """
        command -v podman >/dev/null 2>&1 && echo 'PODMAN=yes' || echo 'PODMAN=no'
        podman image exists \(AppConstants.serverGoImage) 2>/dev/null && echo 'IMAGE=yes' || echo 'IMAGE=no'
        \(containerCmd)
        df -h / 2>/dev/null | awk 'NR==2{printf "DISK=%s/%s\\n",$3,$2}'
        free -m 2>/dev/null | awk 'NR==2{printf "RAM=%sM/%sM\\n",$3,$2}'
        uptime 2>/dev/null | sed 's/.*up *//;s/,.*load.*//' | awk '{printf "UPTIME=%s\\n",$0}'
        echo 'READINESS_END'
        """
    }

    /// Throws `ProvisionError.parseFailed` when the reading is inconclusive —
    /// the script did not run to its sentinel, or `podman ps` itself failed on
    /// a host that has a container on record. Callers keep the last real
    /// reading in that case; an absent container is reported only when podman
    /// actually said so (exit 0, empty list).
    static func parseReadiness(from output: String,
                                containerName: String?) throws -> VPSReadinessState {
        var podman = false
        var sawPodmanLine = false
        var image  = false
        var containerStatus = ""
        var containerRC: Int? = nil
        var sawEnd = false
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("PODMAN=") { sawPodmanLine = true }
            if t == "PODMAN=yes" { podman = true }
            if t == "IMAGE=yes"  { image  = true }
            if t.hasPrefix("CONTAINER_RC=") {
                containerRC = Int(t.dropFirst("CONTAINER_RC=".count))
            } else if t.hasPrefix("CONTAINER=") {
                containerStatus = String(t.dropFirst("CONTAINER=".count))
            }
            if t == "READINESS_END" { sawEnd = true }
        }
        guard sawPodmanLine, sawEnd else {
            throw ProvisionError.parseFailed("readiness probe returned an incomplete reading")
        }
        guard podman else { return .noPodman }
        guard image  else { return .noImage }
        if containerName == nil { return .imageReady }
        if containerStatus.isEmpty {
            // `podman ps` printed nothing: trust that only if it also exited 0.
            if let rc = containerRC, rc == 0 { return .imageReady }
            throw ProvisionError.parseFailed("podman ps failed (exit \(containerRC.map(String.init) ?? "?")) — keeping the last reading")
        }
        if containerStatus.hasPrefix("Up") { return .containerRunning(containerStatus) }
        // Normalize raw podman status strings for display.
        // "Initialized" = container created but never started; show nothing extra.
        // "Exited (0) …" = clean stop; show approximate time if available.
        // "Exited (N) …" = crashed; flag it.
        let displayLabel: String
        if containerStatus == "Initialized" || containerStatus.isEmpty {
            displayLabel = ""
        } else if containerStatus.hasPrefix("Exited (0)") {
            let tail = containerStatus.dropFirst("Exited (0) ".count)
            displayLabel = tail.isEmpty ? "stopped" : "stopped \(tail)"
        } else if containerStatus.hasPrefix("Exited") {
            displayLabel = "exited with error — check container logs"
        } else {
            displayLabel = containerStatus
        }
        return .containerStopped(displayLabel)
    }

    static func parseVPSStats(from output: String) -> VPSStats? {
        var disk = ""; var ram = ""; var uptime = ""
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("DISK=")   { disk   = String(t.dropFirst(5)) }
            if t.hasPrefix("RAM=")    { ram    = String(t.dropFirst(4)) }
            if t.hasPrefix("UPTIME=") { uptime = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        guard !disk.isEmpty || !ram.isEmpty || !uptime.isEmpty else { return nil }
        return VPSStats(disk: disk, ram: ram, uptime: uptime)
    }

    static func containerStatus(host: ServerHost, secret: SSHSecret,
                                 containerName: String,
                                 onStep: @Sendable @escaping (String) -> Void) async throws -> ContainerStatus {
        onStep("podman ps…")
        // `-a` so stopped containers also surface; `^…$` anchors the name filter so a
        // partial match (olcrtc-server-abc vs olcrtc-server-abc-2) can't fool us.
        let raw = try await _withConnection(host: host, secret: secret) { client in
            try await execute(client: client, label: "container status",
                              command: "podman ps -a --filter 'name=^\(containerName)$' --format '{{.Status}}'")
        }
        return ContainerStatus.parse(from: raw)
    }

    static func containerLogs(host: ServerHost, secret: SSHSecret,
                               containerName: String, tail: Int,
                               onStep: @Sendable @escaping (String) -> Void) async throws -> String {
        onStep("podman logs --tail \(tail)…")
        // Container name comes from our own install script so single-quoting is safe.
        // #331: `logBody: false` — this output IS the container's own log, so the
        // caller (Provisioner.containerLogs) routes it to the per-server Container
        // tab; provisioning keeps just the pointer line instead of duplicating it.
        return try await _withConnection(host: host, secret: secret) { client in
            try await _execute(client: client, label: "container logs",
                               command: "podman logs --tail \(tail) '\(containerName)'",
                               logBody: false)
        }
    }

    static func reboot(host: ServerHost, secret: SSHSecret,
                        onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningRebooting.localized())
        // sshd dies as soon as reboot runs — any error from execute is expected and ignored.
        try await _withConnection(host: host, secret: secret) { client in
            _ = try? await execute(client: client, label: "reboot",
                                   command: "nohup sudo reboot >/dev/null 2>&1 &\nexit 0")
        }
    }

    /// The one line of an install log that says why it ended without a link:
    /// the last `ERROR` line, else the last non-empty line, cut short.
    static func installFailureReason(_ log: String) -> String {
        let lines = log.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? "—"
        return String(line.prefix(120))
    }

    // MARK: SSH primitives

    /// What an operation runs its commands on: an SSH session, or the host's
    /// agent when the host came from a device invite and has no SSH login.
    enum ServerLink {
        case ssh(SSHClient)
        case agent(AgentClient)

        func close() async {
            if case .ssh(let client) = self { try? await client.close() }
        }
    }

    /// Runs `body` with an SSH connection and guarantees the connection is closed
    /// whether the body succeeds or throws — replaces the repeated
    /// `try? await client.close()` pattern that existed in every SSHRunner function.
    ///
    /// Named with a `_` prefix to signal it is implementation-internal; exposed
    /// as `internal` (not `private`) so `CitadelSSHClient` in the same module
    /// can bridge the `SSHClientProtocol` abstraction to real Citadel transport.
    // boc #462: `connect` now also hands back the loopback relay that carried the
    // session (nil on the direct path). The relay owns a listener + an outbound
    // SOCKS leg, so it must be torn down on exactly the paths that close the
    // client — hence it is released here rather than inside `connect`.
    // #462 was: `let client = try await connect(host: host, secret: secret)`
    @discardableResult
    static func _withConnection<T>(
        host: ServerHost, secret: SSHSecret,
        _ body: (ServerLink) async throws -> T
    ) async throws -> T {
        let (client, relay) = try await connect(host: host, secret: secret)
        do {
            let result = try await body(client)
            await client.close()
            relay?.close()          // #462: idempotent, fire-and-forget
            return result
        } catch {
            // #462 (audit): the self-teardown case. An op that restarts or stops
            // the exit container (reconfigure, update, rotateKey, stop,
            // uninstall, reboot) kills the tunnel it is riding the moment the
            // command lands, so the SOCKS leg dies before the reply comes back
            // and the user got nothing but a raw Citadel channel error. Sample
            // the relay BEFORE tearing it down and say what actually happened —
            // including that the command probably DID run server-side, which is
            // the part that decides what the owner should do next.
            // #470: PROXY mode only. In VPN mode there is no relay to sample
            // (`SSHTransport.route` dials direct inside the packet tunnel), so
            // the same self-teardown surfaces as a bare Citadel error here; the
            // caller has to decide "this op restarts the container the live
            // record rides" BEFORE the op (ServersView's `isLiveRow`).
            let tunnelCollapsed = relay?.isTransportDown ?? false
            await client.close()
            relay?.close()          // #462
            if tunnelCollapsed {
                throw ProvisionError.sshConnect(
                    L10n.sshTunnelDroppedMidOp_fmt.formatted(error.localizedDescription))
            }
            throw error
        }
    }
    // eoc #462

    /// A logged-in session that the caller keeps open (`SSHReadSessions`);
    /// every other caller goes through `_withConnection`, which closes it.
    static func openConnection(host: ServerHost, secret: SSHSecret)
        async throws -> (client: ServerLink, relay: SSHTunnelRelay?)
    {
        try await connect(host: host, secret: secret)
    }

    /// #451: builds the Citadel authentication method for `secret`.
    ///
    /// Key parsing intentionally happens HERE (and is pre-flighted before the
    /// connect retry loop) so malformed key material fails once with a precise
    /// message instead of being retried as a network error.
    ///
    /// Citadel API (verified against the repo at 0.12.1; project.yml resolves
    /// `from: "0.6.0"` → latest 0.x — CI must confirm these symbols exist in
    /// the resolved version):
    ///   - `SSHAuthenticationMethod.ed25519(username:privateKey:)` with
    ///     `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`
    ///   - `SSHAuthenticationMethod.rsa(username:privateKey:)` with
    ///     `Insecure.RSA.PrivateKey(sshRsa:decryptionKey:)`
    /// Both parsers accept ONLY the OpenSSH text format; encrypted keys are
    /// supported for aes128/256-ctr + bcrypt (the ssh-keygen default), with
    /// the passphrase passed as `decryptionKey` bytes. ECDSA has no text
    /// parser — rejected with guidance. The `.init` contextual form avoids
    /// naming the Crypto module types directly.
    static func authenticationMethod(username: String, secret: SSHSecret) throws -> SSHAuthenticationMethod {
        switch secret {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .agent:
            // Never dialled: `connect` answers an agent host before it gets here.
            throw ProvisionError.sshConnect(L10n.hostAgentOnlyNoKey.localized())
        case .privateKey(let text, let passphrase):
            // Empty passphrase == no passphrase (the field is optional in the UI).
            let decryptionKey: Data?
            if let pp = passphrase, !pp.isEmpty { decryptionKey = Data(pp.utf8) }
            else                                { decryptionKey = nil }
            switch SSHKeyAnalyzer.detect(text) {
            case .ed25519:
                return try .ed25519(username: username,
                                    privateKey: .init(sshEd25519: text, decryptionKey: decryptionKey))
            case .rsa:
                return try .rsa(username: username,
                                privateKey: .init(sshRsa: text, decryptionKey: decryptionKey))
            case .ecdsa:
                throw ProvisionError.sshConnect(L10n.sshKeyErrorECDSA.localized())
            case .unsupportedFormat:
                throw ProvisionError.sshConnect(L10n.sshKeyErrorUnsupportedFormat.localized())
            case .notAKey:
                // Trial-parse fallback: our detector may lag an exotic-but-valid
                // OpenSSH file — let Citadel's parsers have the final word
                // (ed25519 first, then RSA) before rejecting.
                if let m = try? SSHAuthenticationMethod.ed25519(
                        username: username,
                        privateKey: .init(sshEd25519: text, decryptionKey: decryptionKey)) {
                    return m
                }
                if let m = try? SSHAuthenticationMethod.rsa(
                        username: username,
                        privateKey: .init(sshRsa: text, decryptionKey: decryptionKey)) {
                    return m
                }
                throw ProvisionError.sshConnect(L10n.sshKeyErrorNotAKey.localized())
            }
        }
    }

    // boc #462: SSH now rides the app's own tunnel whenever — and ONLY whenever —
    // the in-app proxy is genuinely connected (see `SSHTransport.route`). During a
    // carrier whitelist window the tunnel survives while a direct dial to the VPS
    // does not, which is exactly when the owner needs to administer the server.
    //
    // Nothing about the Citadel call itself changes: the relay makes the VPS look
    // like `127.0.0.1:<ephemeral>`, and the SOCKS5 handshake is completed by
    // `SSHTunnelRelay.open` BEFORE Citadel dials, so it never eats into Citadel's
    // hardcoded, un-raisable 10 s login window.
    //
    // The retry semantics are untouched — still 2 attempts, still 4 s apart. The
    // only addition is which route each attempt takes (`SSHTransport.nextRoute`):
    // a failed tunnel attempt falls back to direct, a failed direct attempt
    // retries through the tunnel if one genuinely exists. Never more than once
    // each way, never a speculative tunnel attempt.
    //
    // `reconnect:` MUST stay `.never`: Citadel's reconnect re-dials the stored
    // host/port, which for a torn-down single-use relay is a dead loopback port.
    //
    // #462 was: `private static func connect(...) async throws -> SSHClient`, which
    // always dialled `host.host:host.port` directly.
    //
    // Retries once after 4 s — handles transient TCP hiccups without the full
    // 30 s wait twice. If both attempts fail, surfaces the host+port so the
    // user knows exactly what couldn't be reached.
    private static func connect(host: ServerHost, secret: SSHSecret)
        async throws -> (client: ServerLink, relay: SSHTunnelRelay?)
    {
        // An invited host: no SSH, the same scripts run through the agent's
        // `exec`, over the routes the agent client picks (tunnel, then direct).
        if case .agent = secret {
            guard let client = AgentClient.exec(for: host) else {
                throw ProvisionError.sshConnect(L10n.hostAgentOnlyNoKey.localized())
            }
            await MainActor.run { LogStore.shared.log(.provisioning, "→ agent: \(host.host):\(host.port)") }
            return (.agent(client), nil)
        }
        // boc #481: trust binds to the VPS, not the ephemeral relay endpoint.
        // First use is automatic; known identities and legacy explicit pins
        // still fail closed on changes, before authentication can complete.
        let trustStore = SSHHostKeyTrustStore.shared
        let trustContext = try trustStore.prepare(
            host: host.host, port: host.port, legacyPin: host.sshHostKeyPin)
        // eoc #481
        // #451: pre-flight the credential OUTSIDE the retry loop — a bad key /
        // wrong key format throws immediately with its own message instead of
        // being retried and re-wrapped as a connect failure.
        _ = try authenticationMethod(username: host.username, secret: secret)
        var previousRoute: SSHTransport.Route?
        // #470: a relay that failed to open already spent the tunnel path's
        // budget (up to 15 s), but `previousRoute` recorded the DIRECT dial that
        // replaced it — so attempt 2 asked `nextRoute` for the tunnel again and
        // paid the same 15 s twice, against the "once each way" rule above.
        // Remember the failure for the rest of THIS connect and snapshot only
        // the direct path after it.
        var tunnelPathFailed = false
        for attempt in 1...2 {
            // #462: re-snapshot per attempt — the tunnel may have come up (or
            // dropped) since the last one, and an honest answer now beats a
            // cached one. In VPN mode this is always `.direct`: the packet tunnel
            // already carries the direct dial (default route, no excludes) and
            // there is no in-app SOCKS listener to relay through.
            // #470 was: `let available = await SSHTransport.currentRoute()`
            var available = SSHTransport.Route.direct
            if !tunnelPathFailed { available = await SSHTransport.currentRoute() }
            let requested = SSHTransport.nextRoute(attempt: attempt,
                                                   previous: previousRoute,
                                                   available: available)
            // #462 (degrade safely): if the relay can't be built for ANY reason we
            // fall back to today's direct connect rather than failing the op.
            let relay = await openRelay(for: requested, host: host)
            if relay == nil, requested.isTunnel { tunnelPathFailed = true }   // #470
            let route: SSHTransport.Route = (relay == nil) ? .direct : requested
            previousRoute = route

            let dialHost = (relay == nil) ? host.host : "127.0.0.1"
            let dialPort = relay?.localPort ?? host.port
            let routeLine = relay.map {
                "→ SSH \(route.label): 127.0.0.1:\($0.localPort) → \(host.host):\(host.port)"
                    + " (SOCKS 127.0.0.1:\($0.socksPort))"
            } ?? "→ SSH \(route.label): \(host.host):\(host.port)"
            await MainActor.run { LogStore.shared.log(.provisioning, routeLine) }

            let started = Date()
            let hostKeyValidator = SSHAutomaticHostKeyValidator(
                context: trustContext, store: trustStore)
            do {
                // Fresh delegate per attempt — cheap (the pre-flight proved it
                // parses), and avoids reusing any per-connection state Citadel
                // may keep inside the method object.
                let client = try await SSHClient.connect(
                    host: dialHost,
                    port: dialPort,
                    authenticationMethod: try authenticationMethod(username: host.username, secret: secret),
                    // #481 was: hostKeyValidator: .acceptAnything()
                    hostKeyValidator: .custom(hostKeyValidator),
                    reconnect: .never
                )
                // #462: the elapsed time IS the diagnostic — Citadel fails the
                // login at a hardcoded 10 000 ms that no setting can raise, and
                // the tunnelled path spends ~5 RTT inside it.
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    LogStore.shared.log(.provisioning,
                        "✓ SSH connected \(host.host):\(host.port) \(route.label)"
                        + " — login \(elapsedMs) ms (Citadel cap 10000 ms)")
                }
                return (.ssh(client), relay)
            } catch {
                relay?.close()   // #462: never leave a listener behind on a retry
                // #481: identity failures are terminal, not transport failures.
                // Never retry a mismatched peer through a different route.
                if let identityError = hostKeyValidator.rejection ?? (error as? SSHHostKeyError) {
                    throw identityError
                }
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                let desc = "\(error)"
                await MainActor.run {
                    LogStore.shared.log(.provisioning,
                        L10n.sshAttemptFailed_fmt.formatted(attempt, desc))
                    LogStore.shared.log(.provisioning,
                        "    \(route.label), \(elapsedMs) ms")
                }
                if attempt < 2 {
                    await MainActor.run {
                        LogStore.shared.log(.provisioning, L10n.sshRetryIn4s.localized())
                    }
                    try await Task.sleep(for: .seconds(Self.sshRetryDelay))
                } else {
                    let isTimeout = desc.lowercased().contains("timeout")
                    // boc #470: on the tunnel route the relay exists only because
                    // the SOCKS CONNECT to host:port already succeeded — the port
                    // DID respond. A timeout there is Citadel's fixed 10 s login
                    // window expiring on the relayed path, so name that instead of
                    // sending the user to check whether SSH is open.
                    // #470 was: `let hint = isTimeout ? sshPortNotResponding_fmt… : desc`
                    let hint: String
                    if !isTimeout {
                        hint = desc
                    } else if route.isTunnel {
                        hint = L10n.sshTunnelLoginTimedOut_fmt.formatted(host.host, host.port)
                    } else {
                        hint = L10n.sshPortNotResponding_fmt.formatted(host.port, host.host)
                    }
                    // eoc #470
                    throw ProvisionError.sshConnect(hint)
                }
            }
        }
        preconditionFailure("unreachable: connect() loop must always return")
    }

    /// #462: builds the loopback relay for a `.tunnel` route, or returns nil.
    ///
    /// Returning nil is the "degrade safely" path: `.direct` routes never need a
    /// relay, and a relay that cannot be opened (tunnel dropped between the
    /// snapshot and now, listener refusing, credentials rejected, handshake
    /// timeout) logs why and lets the caller dial directly instead of failing the
    /// operation. Never logs the SOCKS credentials — only the port.
    private static func openRelay(for route: SSHTransport.Route,
                                  host: ServerHost) async -> SSHTunnelRelay? {
        guard case .tunnel(let socksPort) = route else { return nil }
        do {
            return try await SSHTunnelRelay.open(
                targetHost: host.host,
                targetPort: host.port,
                socksPort:  socksPort,
                credentials: TunnelManager.liveSocksCredentials)
        } catch {
            let detail = "\(error)"
            await MainActor.run {
                LogStore.shared.log(.provisioning,
                    "⚠ SSH tunnel path unavailable (SOCKS 127.0.0.1:\(socksPort)):"
                    + " \(detail) — using the direct path for this attempt")
            }
            return nil
        }
    }

    /// #462: reachability probe that follows the SSH route instead of always
    /// testing the public IP. Exposed so `Provisioner.ensureReachable` and the
    /// install poll loop share one definition of "can we reach this VPS?".
    static func reachabilityProbe(host: String, port: Int,
                                  timeout: TimeInterval = probeTimeout)
        async -> (success: Bool, ms: Double?, viaTunnel: Bool)
    {
        await SSHTransport.probeReachable(host: host, port: port, timeout: timeout)
    }
    // eoc #462

    /// Executes one shell command. stderr is merged into stdout so the user
    /// sees error detail (apt errors, podman errors etc.) in the log instead
    /// of just a bare "exit code 1" from Citadel.
    ///
    /// Named with a `_` prefix to signal it is implementation-internal; exposed
    /// as `internal` so `CitadelSSHClient` can call it from the same module.
    @discardableResult
    static func _execute(client: ServerLink,
                          label: String,
                          command: String,
                          // #331: classify the body by ORIGIN. Orchestration
                          // commands (the default) dump their output into the
                          // .provisioning stream as before. A command whose
                          // output is *container-produced* (e.g. `podman logs`)
                          // passes `logBody: false`: the caller routes that body
                          // to the per-server container log (logContainer, #295),
                          // and provisioning records only a single pointer line
                          // so the orchestration narrative stays followable
                          // without repeating the container output in two tabs.
                          logBody: Bool = true) async throws -> String {
        // Wrap in a brace group so the redirect applies to everything.
        // Trim long previews in the input log entry so we don't dump
        // 50 lines of shell into the buffer.
        let preview = command
            .replacingOccurrences(of: "\n", with: " | ")
            .prefix(120)
        await MainActor.run {
            LogStore.shared.log(.provisioning, "→ exec: \(label)")
            LogStore.shared.log(.provisioning, "    $ \(preview)\(command.count > 120 ? "…" : "")")
        }

        // The command runs in a subshell, so an `exit 1` inside it ends only the
        // subshell; its status is printed after it and the exec itself always
        // succeeds. Citadel discards the output of a failed exec — and with it
        // the script's own `ERROR:` line, the one thing that says what went
        // wrong — so a failure used to reach the user as "command failed (1)".
        let wrapped = "(\n\(command)\n) 2>&1; printf '\\n\(exitMarker)%s\\n' \"$?\""

        let raw: String
        do {
            switch client {
            case .ssh(let ssh):
                let buffer = try await ssh.executeCommand(wrapped)
                let bytes  = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
                raw = String(decoding: bytes, as: UTF8.self)
            case .agent(let agent):
                // The agent runs the same wrapped script with bash, so the exit
                // status rides the marker exactly as it does over SSH.
                raw = try await agent.exec(script: wrapped, timeout: 600).output
            }
        } catch {
            // The connection or the channel failed, not the command: log the raw
            // error, plus the command label so the user knows which step.
            let detail = "\(error)"
            await MainActor.run {
                LogStore.shared.log(.provisioning, "✗ exec failed: \(label)")
                LogStore.shared.log(.provisioning, "    error: \(detail)")
            }
            throw ProvisionError.sshCommand("\(label) — \(error.localizedDescription)")
        }
        let (output, status) = splitExitStatus(raw)
        await MainActor.run {
            LogStore.shared.log(.provisioning, "← \(output.count) bytes:")
            if logBody {
                for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                    LogStore.shared.log(.provisioning, "    \(line)")
                }
            } else {
                // #331: hand-off pointer — the body lives in the Container tab.
                LogStore.shared.log(.provisioning, "    → container output → Container tab")
            }
        }
        if let status, status != 0 {
            let reason = failureReason(output) ?? "exit \(status)"
            await MainActor.run {
                LogStore.shared.log(.provisioning, "✗ exec failed: \(label) (exit \(status))")
            }
            throw ProvisionError.sshCommand("\(label) — \(reason)")
        }
        return output
    }

    /// What `_execute` prints after the command, followed by its exit status.
    static let exitMarker = "__OLCOS_EXIT="

    /// PURE. Splits the exit status `_execute` appended off the output; nil
    /// status when the marker is missing (the channel ended early).
    static func splitExitStatus(_ raw: String) -> (output: String, status: Int?) {
        guard let range = raw.range(of: "\n" + exitMarker, options: .backwards) else { return (raw, nil) }
        let tail = raw[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return (String(raw[..<range.lowerBound]), Int(tail))
    }

    /// PURE. The reason a failed script gives: its last `ERROR:` line, else its
    /// last `[X]` line, else its last line.
    static func failureReason(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func after(_ prefix: String) -> String? {
            lines.last { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        let reason = after("ERROR:") ?? after("[X]") ?? lines.last
        return reason.map { String($0.prefix(300)) }
    }

    private static func execute(client: ServerLink,
                                 label: String,
                                 command: String) async throws -> String {
        try await _execute(client: client, label: label, command: command)
    }

    /// Pulls VALUE from a line shaped like `KEY=VALUE` in the script output.
    static func extract(key: String, from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key)=") {
                return String(trimmed.dropFirst(key.count + 1))
            }
        }
        return nil
    }

    /// Single-pass multi-key extract. Walks `output` once and returns a
    /// `[key: value]` dict for every requested key that was found. Keys
    /// missing from the output are simply absent from the returned dict.
    ///
    /// If a key appears more than once the first occurrence wins, matching
    /// `extract(key:from:)` semantics (which also takes the first match).
    /// That choice matters for `OLCRTC_URI`: the server emits the line once,
    /// but if a future patch ever logged it twice (e.g. for retry diagnostics),
    /// we still resolve the first value the install produced.
    static func extract(keys: [String], from output: String) -> [String: String] {
        var remaining = Set(keys)
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            if remaining.isEmpty { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for key in remaining {
                if trimmed.hasPrefix("\(key)=") {
                    result[key] = String(trimmed.dropFirst(key.count + 1))
                    remaining.remove(key)
                    break
                }
            }
        }
        return result
    }

    // MARK: Reconfigure script

    /// Shell script that rewrites the running container's `server.yaml`
    /// in-place (provider / room id / transport) and restarts the container so
    /// the new config is picked up. Everything else in the file — encryption
    /// key, DNS, SOCKS, transport-specific blocks — is preserved verbatim.
    ///
    /// Strategy:
    ///   1. `podman inspect` → find the bind-mount source dir on the host; that
    ///      is where `srv.sh` wrote `server.yaml` (mounted at /app).
    ///   2. `sed -i` the three mutable YAML fields in `server.yaml`.
    ///   3. `podman restart` — the container CMD is unchanged
    ///      (`sh -c "./olcrtc server.yaml"`), so a restart just re-reads the
    ///      edited file.
    ///
    /// Why `podman restart` (vs the old remove/recreate)? The process arguments
    /// no longer change — only the mounted YAML does — so a restart suffices and
    /// keeps the container, its name, and its writable layer (e.g. the
    /// apk-installed ffmpeg for videochannel) intact.
    ///
    /// Why not re-run srv.sh? That would run apt-get + git clone + go build —
    /// the whole 10–20 min install — just to change three fields.
    static func reconfigureScript(containerName: String, env: [String]) -> String {
        // env is ["OLCRTC_CARRIER=jitsi","OLCRTC_TRANSPORT=vp8channel","OLCRTC_ROOM_ID=…"]
        func envVal(_ key: String) -> String {
            (env.first(where: { $0.hasPrefix("\(key)=") }).map { String($0.dropFirst(key.count + 1)) }) ?? ""
        }
        let safeCarrier   = shellSafe(envVal("OLCRTC_CARRIER"))
        let safeTransport = shellSafe(envVal("OLCRTC_TRANSPORT"))
        let safeRoomID    = shellSafe(envVal("OLCRTC_ROOM_ID"))
        let safeCname     = shellSafe(containerName)
        // #451: wbstream account token → `auth.token` (finding: reconfigure
        // could neither set nor clear it, so switching TO wbstream lost the
        // token and switching AWAY left a stale one). The sed pass below
        // always deletes any `  token:` line (the only `token:` key srv.sh
        // ever writes lives under auth:), then — when the new carrier is
        // wbstream and a token was supplied — re-inserts it right after the
        // freshly rewritten provider line. The insert uses `s|…|&\n  token…|`
        // (not `a\`) because GNU sed's one-line `a\` strips the leading
        // 2-space YAML indent the key needs.
        let safeToken = shellSafe(envVal("OLCRTC_WB_TOKEN"))
        let tokenInsert = (envVal("OLCRTC_CARRIER") == "wbstream" && !safeToken.isEmpty)
            ? "\n            -e 's|^  provider: .*|&\\n  token: \"\(safeToken)\"|' \\"
            : ""
        // MTS Link's frame rate and batch (Vp8Tuning) must reach a config that
        // was written before the numbers were raised, and a room change is the
        // only moment the app touches it. Only the `vp8:` block is rewritten
        // (the `sei:` and `video:` blocks have their own `fps:`), and only when
        // the block exists.
        let vp8FPS = Int(shellSafe(envVal("OLCRTC_VP8_FPS")))
        let vp8Batch = Int(shellSafe(envVal("OLCRTC_VP8_BATCH")))
        let vp8Insert: String
        if envVal("OLCRTC_CARRIER") == "mtslink", envVal("OLCRTC_TRANSPORT") == "vp8channel",
           let vp8FPS, let vp8Batch {
            vp8Insert = "\n            -e '/^vp8:/,/^[a-z]/{s|^  fps: .*|  fps: \(vp8FPS)|;s|^  batch_size: .*|  batch_size: \(vp8Batch)|}' \\"
        } else {
            vp8Insert = ""
        }
        // sed delimiter is `|`; shellSafe strips `|`, `&`, and `\` from the
        // values, so neither the delimiter nor sed replacement metachars can
        // appear in them. srv.sh indents these YAML keys exactly 2 spaces and
        // each appears once (provider→auth, id→room, transport→net), so the
        // anchored `^  key:` patterns are unambiguous. The -e expressions run
        // in order on each line, so the token insert (matching the REWRITTEN
        // provider line via `&`) composes with the provider rewrite in one
        // sed pass, while `/^  token: /d` removes only the pre-existing line.
        return #"""
        set -e
        CNAME="\#(safeCname)"
        if ! podman ps -a --format '{{.Names}}' | grep -q "^${CNAME}$" 2>/dev/null; then
            echo "ERROR: container ${CNAME} not found" >&2; exit 1
        fi
        echo "RECONFIGURE: locating the config for ${CNAME}…"
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}")
        # boc #466: every sibling carrier mounts the SAME deploy dir, so
        # "${DEPLOY_DIR}/server.yaml" — what this used to hardcode — is the
        # PRIMARY's config no matter which container was asked for. Reconfiguring
        # a sibling therefore overwrote the primary's carrier and room, silently
        # destroying that protocol, while the restart re-read the sibling's own
        # untouched file: the change looked like it succeeded and landed nowhere.
        # The container's own command names the file it actually reads
        # ("sh -c ./olcrtc server-telemost.yaml") — the one source that cannot
        # disagree with reality, and it corrects every caller at once instead of
        # trusting each to pass the right name. `grep -oE` prints one match per
        # line on its own, so no `tr` and no escapes are needed here.
        CONFIG_NAME=$(podman inspect --format '{{range .Config.Cmd}}{{.}} {{end}}' "${CNAME}" | grep -oE 'server[A-Za-z0-9_.-]*[.]yaml' | tail -1)
        if [ -z "$CONFIG_NAME" ]; then CONFIG_NAME="server.yaml"; fi
        CONFIG="${DEPLOY_DIR}/${CONFIG_NAME}"
        # eoc #466
        if [ -z "$DEPLOY_DIR" ] || [ ! -f "$CONFIG" ]; then
            echo "ERROR: ${CONFIG_NAME} not found for ${CNAME} (deploy dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        echo "RECONFIGURE: updating ${CONFIG}…"
        sed -i \
            -e '/^  token: /d' \
            -e 's|^  provider: .*|  provider: "\#(safeCarrier)"|' \\#(tokenInsert)
            -e 's|^  id: .*|  id: "\#(safeRoomID)"|' \
            -e 's|^  transport: .*|  transport: "\#(safeTransport)"|' \\#(vp8Insert)
            "$CONFIG"
        echo "RECONFIGURE: restarting ${CNAME} with carrier=\#(safeCarrier) transport=\#(safeTransport) id=\#(safeRoomID)…"
        # The restart follows the answer, at the end of the script: it no longer runs here.
        # #451 was: KEY=$(cat ~/.olcrtc_key || echo "") — when the key file was
        # missing the URI ended in a bare '#', OlcrtcURI.parse threw
        # missingField(key), and the caller's `try?` silently skipped the
        # ConnectionRecord update. server.yaml still holds the key (srv.sh
        # writes both), so fall back to reading it from the config.
        KEY=$(cat ~/.olcrtc_key 2>/dev/null | tr -d '[:space:]')
        [ -n "$KEY" ] || KEY=$(sed -n 's/^  key: "\(.*\)"/\1/p' "$CONFIG")
        echo "OLCRTC_URI=olcrtc://\#(safeCarrier)?\#(safeTransport)@\#(safeRoomID)#${KEY}"
        echo "OLCRTC_RECONFIGURED=ok"
        # The restart comes after the answer, on its own: a tunnel that runs through this server dies
        # with the container, and an answer written after the restart never arrives (the app then takes
        # a change that was made for one that failed). The script ends first; two seconds later the
        # container restarts, and is started if the restart stopped it halfway.
        nohup sh -c 'sleep 2; podman restart "$1" >/dev/null 2>&1 || podman start "$1" >/dev/null 2>&1' _ "${CNAME}" >/dev/null 2>&1 &
        """#
    }

    /// Returns the new `olcrtc://` URI emitted by the reconfigure script,
    /// or nil if the script did not emit one (older server without ~/.olcrtc_key).
    @discardableResult
    static func reconfigure(host: ServerHost, secret: SSHSecret,
                             containerName: String, env: [String],
                             onStep: @Sendable @escaping (String) -> Void) async throws -> String? {
        onStep(L10n.provisioningReconfiguring.localized())
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await execute(client: client, label: "reconfigure",
                              command: reconfigureScript(containerName: containerName, env: env))
        }
        return extract(key: "OLCRTC_URI", from: output)
    }

    // MARK: #303 — Recover config script
    //
    // Reads the deployed `server.yaml` (written by srv.sh, see scripts/srv.sh
    // "Generate YAML config") and `~/.olcrtc_key` for an existing container,
    // dumping both verbatim between sentinel markers so `parseRecoveredConfig`
    // can rebuild an `olcrtc://` URI without any server-side mutation.
    //
    // Strategy mirrors `reconfigureScript`: `podman inspect` finds the bind-mount
    // source dir (where srv.sh wrote server.yaml), then `cat` the file and the
    // key file. No restart, no edits — read-only.
    // #452: configFile — sibling carriers keep their config as
    // server-<carrier>.yaml in the same deploy dir (carrierYAMLFile), so
    // per-carrier recovery passes that name. The default preserves the
    // original single-config behaviour.
    static func recoverConfigScript(containerName: String,
                                    configFile: String = "server.yaml") -> String {
        let safeCname = shellSafe(containerName)
        let safeConfig = shellSafe(configFile)
        return #"""
        set -e
        CNAME="\#(safeCname)"
        if ! podman ps -a --format '{{.Names}}' | grep -q "^${CNAME}$" 2>/dev/null; then
            echo "ERROR: container ${CNAME} not found" >&2; exit 1
        fi
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}")
        CONFIG="${DEPLOY_DIR}/\#(safeConfig)"
        if [ -z "$DEPLOY_DIR" ] || [ ! -f "$CONFIG" ]; then
            echo "ERROR: \#(safeConfig) not found for ${CNAME} (deploy dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        echo "OLCRTC_RECOVER_YAML_BEGIN"
        # #314: tolerate an unreadable file (was: bare `cat "$CONFIG"`) — the
        # sentinels then bracket an empty body, parseRecoveredConfig throws a
        # typed RecoverConfigError, and the UI can offer the "generate new
        # key" fallback instead of surfacing an opaque SSH exit-1 error.
        cat "$CONFIG" 2>/dev/null || true
        echo "OLCRTC_RECOVER_YAML_END"
        echo "OLCRTC_RECOVER_KEY=$(cat ~/.olcrtc_key 2>/dev/null | tr -d '[:space:]' || echo "")"
        """#
    }

    /// Recovered server-side config, parsed from `recoverConfigScript` output.
    /// Mirrors the subset of `server.yaml` (scripts/srv.sh "Generate YAML config")
    /// needed to rebuild an `olcrtc://` URI.
    struct RecoveredConfig: Equatable, Sendable {
        var carrier  : String
        var transport: String
        var roomID   : String
        var key      : String
        var vp8FPS      : Int?
        var vp8BatchSize: Int?
        // #303: seichannel tuning — only populated when transport == "seichannel".
        // nil means "use OlcrtcConnection's defaults" (matches vp8FPS/vp8BatchSize
        // convention above).
        var seiFPS  : Int?
        var seiBatch: Int?
        var seiFrag : Int?
        var seiACK  : Int?
        // #470: wbstream `auth.token` (srv.sh / add-carrier.sh write it as
        // `  token:` under `auth:`). The client must present the SAME token the
        // server was installed with; recovering without it produced a record
        // that failed auth while the alert said "Recovered wbstream/…".
        // Defaulted so the memberwise construction below stays as it was.
        var wbToken : String = ""
    }

    enum RecoverConfigError: LocalizedError {
        case missingYAML
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .missingYAML:          return L10n.recoverErrorMissingYAML.localized()
            case .missingField(let f):  return L10n.recoverErrorMissingField_fmt.formatted(f)
            }
        }
    }

    /// Parses the `OLCRTC_RECOVER_*` block emitted by `recoverConfigScript` into
    /// a `RecoveredConfig`. The YAML between the BEGIN/END sentinels is the exact
    /// `server.yaml` written by srv.sh (see scripts/srv.sh "Generate YAML config"):
    /// a flat, 2-space-indented structure — no lists, no multi-line scalars — so a
    /// line-based `key: "value"` scan is sufficient and avoids a YAML dependency.
    static func parseRecoveredConfig(from output: String) throws -> RecoveredConfig {
        guard let beginIdx = output.range(of: "OLCRTC_RECOVER_YAML_BEGIN"),
              let endIdx   = output.range(of: "OLCRTC_RECOVER_YAML_END"),
              endIdx.lowerBound > beginIdx.upperBound else {
            throw RecoverConfigError.missingYAML
        }
        let yaml = String(output[beginIdx.upperBound..<endIdx.lowerBound])

        // Strip surrounding quotes (server.yaml quotes all string scalars).
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        // Single-pass line scan. server.yaml keys are unique within their section
        // and srv.sh never repeats a top-level key, so "last value wins" and
        // "first value wins" are equivalent here — last is simplest.
        var values: [String: String] = [:]
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let val = unquote(String(trimmed[trimmed.index(after: colonIdx)...]))
            values[key] = val
        }

        guard let carrier = values["provider"], !carrier.isEmpty else {
            throw RecoverConfigError.missingField("auth.provider")
        }
        guard let roomID = values["id"], !roomID.isEmpty else {
            throw RecoverConfigError.missingField("room.id")
        }
        guard let transport = values["transport"], !transport.isEmpty else {
            throw RecoverConfigError.missingField("net.transport")
        }
        let recoveredKey = extract(key: "OLCRTC_RECOVER_KEY", from: output) ?? ""
        let key = recoveredKey.isEmpty ? (values["key"] ?? "") : recoveredKey
        guard !key.isEmpty else {
            throw RecoverConfigError.missingField("crypto.key")
        }

        var vp8FPS: Int?
        var vp8BatchSize: Int?
        if transport == "vp8channel" {
            vp8FPS       = values["fps"].flatMap(Int.init)
            vp8BatchSize = values["batch_size"].flatMap(Int.init)
        }

        // #303: seichannel tuning (scripts/srv.sh "sei:" block) — same flat
        // scan as vp8 above; the gate on transport keeps this from picking up
        // unrelated "fps"/"batch_size" keys from a different transport block.
        var seiFPS  : Int?
        var seiBatch: Int?
        var seiFrag : Int?
        var seiACK  : Int?
        if transport == "seichannel" {
            seiFPS   = values["fps"].flatMap(Int.init)
            seiBatch = values["batch_size"].flatMap(Int.init)
            seiFrag  = values["fragment_size"].flatMap(Int.init)
            seiACK   = values["ack_timeout_ms"].flatMap(Int.init)
        }

        // #470: the token is carrier-bound (only a WB Stream server, which the
        // app no longer installs but still reads, writes one), so the same gate
        // here — a stray `token:` under another provider is not something the
        // client should start sending.
        let wbToken = carrier == "wbstream" ? (values["token"] ?? "") : ""

        return RecoveredConfig(carrier: carrier, transport: transport, roomID: roomID, key: key,
                               vp8FPS: vp8FPS, vp8BatchSize: vp8BatchSize,
                               seiFPS: seiFPS, seiBatch: seiBatch, seiFrag: seiFrag, seiACK: seiACK,
                               wbToken: wbToken)   // #470
    }

    /// Reads the deployed `server.yaml` + `~/.olcrtc_key` for `containerName` and
    /// returns the parsed config — read-only, no server mutation.
    static func recoverConfig(host: ServerHost, secret: SSHSecret,
                               containerName: String,
                               configFile: String = "server.yaml",   // #452
                               onStep: @Sendable @escaping (String) -> Void) async throws -> RecoveredConfig {
        onStep(L10n.provisioningRecovering.localized())
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await execute(client: client, label: "recover-config",
                              command: recoverConfigScript(containerName: containerName,
                                                           configFile: configFile))
        }
        return try parseRecoveredConfig(from: output)
    }

    // MARK: #314 — Rotate key ("generate new key" fallback for #303)
    //
    // When recoverConfig finds server.yaml unreadable/unparseable, the
    // read-only path cannot extract the key/params. scripts/rotate-key.sh
    // repairs the server instead: it rotates `~/.olcrtc_key` and rewrites
    // server.yaml using srv.sh's verbatim key-generation / YAML-writing lines
    // (parity guarded by Tests/RotateKeyScriptTests.swift), restarts the
    // container, and prints the same OLCRTC_URI= / OLCRTC_CONTAINER= contract
    // as srv.sh — so `parseInstallResult` is reused unchanged.
    //
    // Destructive by design: the new key cuts off every other client of that
    // server. The UI confirms explicitly before calling this.
    static func rotateKey(host: ServerHost, secret: SSHSecret, containerName: String,
                          onStep: @Sendable @escaping (String) -> Void) async throws -> RotateKeyResult {
        onStep(L10n.provisioningRotatingKey.localized())
        let script = try loadBundledScript(named: "rotate-key")
        await MainActor.run { LogStore.shared.log(.provisioning,
            "✓ rotate-key.sh \(script.count) bytes") }
        let b64 = Data(script.utf8).base64EncodedString()
        let safeCname = shellSafe(containerName)
        // Upload over the same base64-printf channel as srv.sh (uploadScript),
        // then run synchronously: openssl + config rewrite + podman restart
        // take seconds (like reconfigureScript), so the nohup/poll install
        // pipeline would be overkill. OLCRTC_CONFIG_NAME is set explicitly to
        // keep the auto-provisioned marker unconditional (see installEnv).
        let output = try await _withConnection(host: host, secret: secret) { client in
            _ = try await execute(client: client, label: "upload rotate-key.sh",
                command: "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.rotateScript)" +
                         " && chmod +x \(RemotePaths.rotateScript)")
            return try await execute(client: client, label: "rotate key",
                command: "OLCRTC_CONTAINER=\(safeCname) OLCRTC_CONFIG_NAME=auto-provisioned " +
                         RemotePaths.rotateScript)
        }
        guard let result = parseInstallResult(from: output) else {
            throw ProvisionError.parseFailed(L10n.rotateKeyFailedNoURI.localized())
        }
        // #452: multi-carrier — rotate-key.sh also rewrites every sibling
        // server-<carrier>.yaml in the deploy dir (one shared key per host)
        // and emits one OLCRTC_SIBLING_URI=<container>|<uri> line per sibling.
        return RotateKeyResult(primary: result, siblings: parseSiblingURIs(from: output))
    }

    // MARK: Uninstall script

    // Container name prefix used by `scripts/srv.sh` (`CONTAINER_NAME="olcrtc-server-$PODMAN_ID"`).
    // Must stay in sync with the server script — a mismatch silently breaks
    // the no-name sweep below and orphans containers on the VPS.
    static let containerNamePrefix = "olcrtc-server-"

    static func deepUninstallScript(containerName: String?, removeImage: Bool) -> String {
        var lines: [String] = []
        if let name = containerName {
            // #470: the `<name>-<carrier>` siblings (#452) bind-mount the deploy dir
            // removed below — take them down first, like uninstallScript (#469).
            lines.append("for c in $(podman ps -a --format '{{.Names}}' | grep '^\(shellSafe(name))-' 2>/dev/null); do podman stop \"$c\" 2>/dev/null; podman rm \"$c\" 2>/dev/null; done")
            lines.append("podman stop \"\(shellSafe(name))\" 2>/dev/null || true")
            lines.append("podman rm \"\(shellSafe(name))\" 2>/dev/null || true")
        } else {
            lines.append("podman ps -a --filter 'name=olcrtc-server-' --format '{{.Names}}' | xargs -r podman stop 2>/dev/null || true")
            lines.append("podman ps -a --filter 'name=olcrtc-server-' --format '{{.Names}}' | xargs -r podman rm 2>/dev/null || true")
        }
        // #431 was: rm -rf /root/olcrtc-deploy-* /tmp/olcrtc-deploy-* — WORK_DIR moved
        //   to /opt in scripts/srv.sh, so the work dirs live there now; sweep all three
        //   (/root + /tmp kept for legacy pre-move installs).
        lines.append("rm -rf /opt/olcrtc-deploy-* /root/olcrtc-deploy-* /tmp/olcrtc-deploy-* 2>/dev/null || true")
        lines.append("rm -rf ~/.cache/olcrtc 2>/dev/null || true")
        lines.append("rm -f ~/.olcrtc_key 2>/dev/null || true")
        // The bond endpoint runs from the Go image and mounts the key just removed.
        lines.append(bondUninstallLines)
        // The HTTPS management agent manages this server; it goes with it.
        lines.append(agentUninstallLines)
        if removeImage {
            lines.append("podman rmi \(AppConstants.serverGoImage) 2>/dev/null || true")
        }
        // Every protocol goes, Xray (VLESS · REALITY) included, and the
        // server that hands out device invites.
        lines.append(xrayUninstallLines)
        lines.append(shareUninstallLines)
        lines.append("echo OLCRTC_DEEP_UNINSTALLED=ok")
        return lines.joined(separator: "\n")
    }

    static func uninstallScript(containerName: String?) -> String {
        // The `target` literal is only used to make the exact-match grep
        // deterministically fail when we have no recorded name — the real
        // cleanup then happens in the `else` sweep branch. Keep it equal
        // to the prefix for readability.
        let target = containerName ?? containerNamePrefix
        return #"""
        set +e
        if podman ps -a --format '{{.Names}}' | grep -q '^\#(target)$' 2>/dev/null; then
            # #469: the siblings (`<base>-<carrier>`, #452) bind-mount the very
            # deploy dir the rm -rf below deletes. Removing only the primary left
            # them running with their config pulled out from under them, and the
            # card claiming "Ready to install".
            for c in $(podman ps -a --format '{{.Names}}' | grep '^\#(target)-' 2>/dev/null); do
                podman stop "$c" 2>/dev/null
                podman rm   "$c" 2>/dev/null
            done
            podman stop "\#(target)" 2>/dev/null
            podman rm   "\#(target)" 2>/dev/null
        else
            for c in $(podman ps -aq --filter 'name=\#(containerNamePrefix)'); do
                podman stop "$c" 2>/dev/null
                podman rm   "$c" 2>/dev/null
            done
        fi
        # #431: WORK_DIR is /opt/olcrtc-deploy-$PODMAN_ID (scripts/srv.sh) — sweep /opt
        # so uninstall removes the work dir; /root + /tmp kept for legacy installs.
        rm -rf /opt/olcrtc-deploy-* /root/olcrtc-deploy-* /tmp/olcrtc-deploy /tmp/olcrtc-build /tmp/olcrtc-deploy-*
        rm -f ~/.olcrtc_key
        # The bond endpoint mounts that key; it goes with the protocols.
        \#(bondUninstallLines)
        # The HTTPS management agent manages this server; remove it too.
        \#(agentUninstallLines)
        # "Remove all protocols" includes Xray (VLESS · REALITY), keys and all.
        \#(xrayUninstallLines)
        echo "OLCRTC_UNINSTALLED=ok"
        """#
    }
}
