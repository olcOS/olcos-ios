import Foundation

// MARK: - WedgeDetector
//
// #440: detects a "wedged" session from the native core's own log lines. The core
// can sit nominally connected while its carrier link is stuck — repeatedly failing
// to (re)open streams — and its internal reconnect doesn't always break the loop.
// Our keep-alive + end-to-end verify eventually catch it, but only after the full
// budget (~120 s). A burst of failure-signature lines in a short window is a much
// earlier tell, so this feeds `TunnelManager.requestReconnect` to restart in ~10 s.
//
// Pure + unit-tested: the caller feeds `(line, now)` and acts on a `true` return.
// Time is injected (monotonic seconds) so the window logic is deterministic under
// test. Gated OFF by default in Settings — log-text signatures are brittle across
// core versions, so this is opt-in, not a silent behaviour change.

struct WedgeDetector {
    /// Failure-signature count within `window` seconds that trips a restart.
    let threshold: Int
    /// Trailing window, in seconds, the failures must fall within.
    let window: Double

    private(set) var timestamps: [Double] = []

    init(threshold: Int, window: Double) {
        self.threshold = threshold
        self.window = window
    }

    /// Substrings that mark a carrier-level (re)connect failure in a core log line.
    /// Lowercased matching; deliberately narrow so ordinary traffic lines don't trip
    /// it. Kept in one place so the brittle contract is easy to audit against a core
    /// version bump.
    // #445 (audit fix 6): refreshed against master's capped reconnect
    // (internal/client/link.go). Master retries at most 3–5 times per burst, and
    // its per-attempt failure warns are "handshake on reconnect failed" /
    // "peer confirmation on reconnect failed" / "wait for peer on reconnect
    // failed" — none of which the old "handshake failed" substring matched.
    // #445 was: also "open stream failed" (with a space) — no such line exists in
    // master; the real line is "OpenStream failed: %v" (tunnel.go), matched by
    // "openstream failed" below.
    // Re-audited against the ghostlane-project/olcrtc core (internal/client/
    // link.go, internal/tunnelcore/control.go): the provider-callback warn and
    // the terminal "keeping listener up" are gone; the core now retries on its
    // own, pausing longer each time, and names more of its failures.
    static let signatures: [String] = [
        "remote not ready",
        "openstream failed",
        "reconnect attempt",
        "dial failed",
        "handshake failed",
        "on reconnect failed",          // covers the three per-attempt link.go warns
        "smux re-init failed",          // link.go: "smux re-init failed (attempt %d)"
        "nobody in the room answered",  // link.go: a round with nobody to handshake with
        "peer refused the handshake",   // link.go: the peer answered and said no
        "data plane has stopped",       // control.go: control alive, data dead
        "pausing before the next try",  // link.go: burst exhausted — also fatal below
    ]

    /// #445 (audit fix 6): signatures that mean the core has given up on the
    /// current burst — trip IMMEDIATELY, no windowing. The core caps a reconnect
    /// burst at 3–5 handshake attempts, then logs "client reconnect: exhausted N
    /// handshake attempts (reason=…) - pausing before the next try" (link.go)
    /// and goes quiet for a pause that grows to five minutes. A fresh start from
    /// the app is the faster way back; waiting for a threshold after that line
    /// is pointless, since nothing further is logged until the pause ends.
    static let fatalSignatures: [String] = [
        "pausing before the next try",
    ]

    static func isFailureSignature(_ line: String) -> Bool {
        let s = line.lowercased()
        return signatures.contains { s.contains($0) }
    }

    static func isFatalSignature(_ line: String) -> Bool {
        let s = line.lowercased()
        return fatalSignatures.contains { s.contains($0) }
    }

    /// Feeds one line seen at `now` (monotonic seconds). Returns true exactly once
    /// per burst — when the count of failure signatures within the trailing window
    /// reaches `threshold` — and clears its window so it won't re-fire until a fresh
    /// burst accumulates. A fatal signature (#445) trips immediately, bypassing the
    /// window entirely.
    mutating func record(line: String, now: Double) -> Bool {
        // #445: the core's own give-up line is terminal — restart now. Clear the
        // window so the (idempotent) restart isn't chased by a stale windowed trip.
        if Self.isFatalSignature(line) {
            timestamps.removeAll()
            return true
        }
        guard Self.isFailureSignature(line) else { return false }
        timestamps.append(now)
        let cutoff = now - window
        timestamps.removeAll { $0 < cutoff }
        if timestamps.count >= threshold {
            timestamps.removeAll()
            return true
        }
        return false
    }

    /// Clears the window (called when a fresh session connects).
    mutating func reset() { timestamps.removeAll() }
}
