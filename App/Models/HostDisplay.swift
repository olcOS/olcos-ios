import SwiftUI

// #263: The single-source VPS display model + its pure reducer, moved out of
// ServersView (introduced in #258, reducer extracted in #259). The View drives
// these transitions; `HostDisplayTests` covers them. The "no status-jump"
// invariants live here:
//   • a probe result is the ONLY thing that sets the base (terminalBase),
//   • while running the card shows the PREVIOUS base, never the optimistic target,
//   • phases advance forward only (advanced), capped at the last milestone,
//   • a failure carries previousBase so Retry (retryBase) can restore it.

/// What the server IS. Set ONLY from a confirmed probe — never optimistically
/// mid-operation. Maps from `VPSReadinessState`.
enum HostBase: Equatable {
    case unknown, noPodman, noImage, imageReady, stopped, running

    init(_ r: VPSReadinessState) {
        switch r {
        case .noPodman:         self = .noPodman
        case .noImage:          self = .noImage
        case .imageReady:       self = .imageReady
        case .containerStopped: self = .stopped
        case .containerRunning: self = .running
        }
    }

    var hasContainer: Bool { self == .running || self == .stopped }

    var tone: OlcStatusTone {
        switch self {
        case .unknown, .noPodman:   return .unknown
        case .noImage:              return .progress   // amber — Podman ok, image not pulled
        // #456 was: .ok — green is now reserved for an end-to-end VERIFIED result;
        // podman "Up" only proves the process exists (the user's telemost container
        // was Up and green while its own logs read `traffic: in=0 out=0`), and
        // `.imageReady` means "nothing installed yet", which was never a success.
        case .imageReady, .running: return .unknown
        case .stopped:              return .warn
        }
    }
    var title: String {
        switch self {
        case .unknown:    return L10n.vpsTitleUnknown.localized()
        // #471 was: `vpsTitleReady` — the same title for "nothing is installed"
        // and "the image is built and ready", two different situations.
        case .noPodman:   return L10n.vpsTitleNothingInstalled.localized()
        case .noImage:    return L10n.vpsTitlePodmanReady.localized()
        case .imageReady: return L10n.vpsTitleReady.localized()
        case .stopped:    return L10n.vpsTitleStopped.localized()
        case .running:    return L10n.vpsTitleRunning.localized()
        }
    }
    var subtitle: String {
        switch self {
        case .unknown:    return L10n.vpsSubUnknown.localized()
        case .noPodman:   return L10n.vpsSubNoPodman.localized()
        case .noImage:    return L10n.vpsSubNoImage.localized()
        case .imageReady: return L10n.vpsSubImageReady.localized()
        case .stopped:    return L10n.vpsSubStopped.localized()
        case .running:    return L10n.vpsSubRunning.localized()
        }
    }
}

/// What we're DOING. `stepCount` sizes the progress-bar denominator (the live
/// provisioner message is the running subtitle); `target` is the nominal resolved
/// state used only when an op doesn't probe.
enum HostOp: Equatable {
    case check, install, start, stop, reconfigure, update, uninstall, deepUninstall, reboot

    var verb: String {
        switch self {
        case .check:         return L10n.vpsVerbChecking.localized()
        case .install:       return L10n.vpsVerbInstalling.localized()
        case .start:         return L10n.vpsVerbStarting.localized()
        case .stop:          return L10n.vpsVerbStopping.localized()
        case .reconfigure:   return L10n.vpsVerbReconfiguring.localized()
        case .update:        return L10n.vpsVerbUpdating.localized()
        case .uninstall:     return L10n.vpsVerbUninstalling.localized()
        case .deepUninstall: return L10n.vpsVerbDeepUninstalling.localized()
        case .reboot:        return L10n.vpsVerbRebooting.localized()
        }
    }

    /// Number of progress milestones — sizes the bar denominator only. The
    /// displayed running subtitle is the live (localized) provisioner message,
    /// not a fixed phase label, so individual step strings aren't needed.
    var stepCount: Int {
        switch self {
        case .check:  return 2
        case .install: return 5
        case .update: return 4
        case .start, .stop, .reconfigure, .uninstall, .deepUninstall, .reboot: return 3
        }
    }

    var target: HostBase? {
        switch self {
        case .check, .reboot:                          return nil      // keep previous base
        case .install, .start, .reconfigure, .update:  return .running
        case .stop:                                    return .stopped
        case .uninstall:                               return .imageReady
        case .deepUninstall:                           return .noPodman
        }
    }
}

/// The ONE display state. The card computes everything (status pill, progress bar,
/// primary button, menu) from this. `previousBase` rides along so Retry / a
/// no-probe success can restore without a second source.
enum HostDisplay: Equatable {
    case base(HostBase)
    case running(op: HostOp, phase: Int, note: String, previousBase: HostBase)
    case failed(op: HostOp, phase: String, message: String, previousBase: HostBase)
}

// MARK: - Reducer (pure — unit-tested in HostDisplayTests)

extension HostBase {
    /// Persisted snapshot ↔ display base (App/Models/NodeHealth.swift). A host
    /// with no snapshot starts as `.unknown` — "checking", never "stopped".
    init(snapshot: HostSnapshotBase) {
        switch snapshot {
        case .unknown:    self = .unknown
        case .noPodman:   self = .noPodman
        case .noImage:    self = .noImage
        case .imageReady: self = .imageReady
        case .stopped:    self = .stopped
        case .running:    self = .running
        }
    }

    var snapshotBase: HostSnapshotBase {
        switch self {
        case .unknown:    return .unknown
        case .noPodman:   return .noPodman
        case .noImage:    return .noImage
        case .imageReady: return .imageReady
        case .stopped:    return .stopped
        case .running:    return .running
        }
    }
}

extension HostDisplay {
    /// The confirmed base under whatever is shown. Running / failed keep the base
    /// they started from — so the card never shows an optimistic state mid-op.
    var base: HostBase {
        switch self {
        case .base(let b):                return b
        case .running(_, _, _, let prev): return prev
        case .failed(_, _, _, let prev):  return prev
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Begin an operation from a confirmed base: phase 0, first milestone note.
    static func start(_ op: HostOp, from base: HostBase) -> HostDisplay {
        .running(op: op, phase: 0, note: L10n.vpsConnecting.localized(), previousBase: base)
    }

    /// Advance a running operation: phase forward only (capped at the last
    /// milestone) + the live note. Non-running states pass through unchanged.
    func advanced(note: String) -> HostDisplay {
        guard case .running(let op, let phase, _, let prev) = self else { return self }
        let next = min(phase + 1, max(op.stepCount - 1, 0))
        return .running(op: op, phase: next, note: note, previousBase: prev)
    }

    /// The ONE terminal base on success: the probe result wins; else the op's
    /// nominal target; else the base we started from. Only a real probe should
    /// pass a non-nil `probed`.
    static func terminalBase(op: HostOp, probed: HostBase?, previous: HostBase) -> HostBase {
        probed ?? op.target ?? previous
    }

    /// Terminal failure: keep the op + the note where it failed, carry the
    /// previous base for Retry. Non-running → unchanged.
    func failed(message: String) -> HostDisplay {
        guard case .running(let op, _, let note, let prev) = self else { return self }
        return .failed(op: op, phase: note, message: message, previousBase: prev)
    }

    /// What Retry restores before re-dispatching the op: the base under a failure.
    func retryBase() -> HostDisplay? {
        guard case .failed(_, _, _, let prev) = self else { return nil }
        return .base(prev)
    }
}

// MARK: - HostHeadline (#456)

/// #456: the ONE headline for a VPS card. Combines what SSH proved about the
/// HOST with what end-to-end probes proved about its PROTOCOLS. Pure → tested.
///
/// This replaces "the podman pill is the card's verdict". Podman status is
/// demoted to a clause of the headline's own subtitle; the headline answers the
/// only question the user actually has: *what is true right now, and what do I
/// do?*
/// #471 was: "…demoted to a caption LINE with its own age" — that line
/// (`ServerCardView.readStamp`) and the failure banner under it are deleted;
/// every fact they carried is an argument to `reduce` now, so the card states
/// its one claim exactly once.
enum HostHeadline: Equatable {
    /// An operation is running. Carries the op's VERB for the title AND the live
    /// provisioner note + step for the subtitle. #470: `step` is the 0-based
    /// `HostDisplay.running.phase` (capped at `stepCount - 1`); `subtitle`
    /// renders it 1-based, like the progress bar.
    /// #456 (audit fix) was: `case busy(String)` holding only the verb, so the
    /// pill rendered "Installing…" as its title and "Installing" as its subtitle
    /// — the same word twice — and the running commentary the user relies on to
    /// see progress (which the provisioner publishes continuously) was dropped.
    case busy(verb: String, note: String, step: Int, of: Int)
    /// The last operation failed: WHICH op, and its message.
    /// #456 (audit fix) was: `case opFailed(String)` (message only), so the title
    /// became a generic "Last action failed" and the user could no longer tell
    /// whether the install, the reconfigure or the uninstall was the thing that
    /// broke.
    case opFailed(verb: String, message: String)
    /// SSH / TCP said no. This is "couldn't check" — requirement 2 — and is NEVER
    /// rendered as stopped or failed, however old the last container reading is.
    case unreachable(age: TimeInterval?)
    /// Nothing has probed this host yet this launch — an honest blank, not a
    /// present-tense claim recycled from a persisted value.
    case notChecked
    /// #469: the last silent probe FAILED (SSH auth, host key, timeout). Grey —
    /// "could not check" is not a verdict about the server — but it names the
    /// reason instead of leaving "Checking the server…" on screen all session.
    case probeFailed(String)
    case containerStopped(age: TimeInterval?)
    case noContainer(HostBase, age: TimeInterval?)
    /// Nothing is in the way: the card answers one question — can this server
    /// be used now? It is usable when any protocol works by the latest evidence
    /// (a verified check, a good one within the last 30 minutes, or the live
    /// tunnel through it), unusable only when every protocol that was checked
    /// failed, and "not checked" otherwise. The protocols that failed are named
    /// (`problemLine`), not averaged into a verdict about the whole server.
    case health(HealthDisplay, tally: ProtocolsTally)

    /// Precedence, strictly in this order:
    /// 1 running op · 2 failed op · 3 SSH/TCP said no ("couldn't check", NEVER
    /// "stopped") · 4 never probed this launch · 5 container stopped ·
    /// 6 nothing installed · 7 the protocols' measured verdict.
    static func reduce(display: HostDisplay,
                       reachable: Bool?,
                       lastProbeAge: TimeInterval?,
                       health: HealthDisplay,
                       probeError: String? = nil,   // #469
                       // What the server's protocols add up to (ServersView
                       // counts them). Last, so a caller that does not count
                       // keeps the summary `health` as its verdict.
                       tally: ProtocolsTally = ProtocolsTally(),
                       // A protocol outside the olcrtc container family (Xray)
                       // is deployed: with no olcrtc container the host is
                       // still not "nothing installed".
                       otherProtocols: Bool = false) -> HostHeadline {
        if case .running(let op, let phase, let note, _) = display {
            return .busy(verb: op.verb, note: note, step: phase, of: op.stepCount)   // #456
        }
        if case .failed(let op, _, let message, _) = display {
            return .opFailed(verb: op.verb, message: message)   // #456
        }
        // Before ANY container reading: an unreachable VPS tells us nothing about
        // the container, so a stale "stopped" must never surface as fact here.
        if reachable == false { return .unreachable(age: lastProbeAge) }
        // #469: a probe that threw is more informative than "not checked yet".
        if lastProbeAge == nil, let probeError { return .probeFailed(probeError) }
        if lastProbeAge == nil { return .notChecked }
        // #469 was: `.containerStopped` whenever the PRIMARY was stopped — the
        // base tracks only that container, so a host whose jitsi primary was
        // stopped while its telemost sibling carried a verified live tunnel
        // read "Server stopped · tap Start server". Measured, fresh evidence
        // that a protocol works outranks one container's podman state.
        // #471: the age rides with the state it dates (see `subtitle`), so the
        // card never needs a second line to say how old its claim is.
        if display.base == .stopped, tally.standing(fallback: health) != .working {
            return .containerStopped(age: lastProbeAge)
        }
        if !display.base.hasContainer, !otherProtocols { return .noContainer(display.base, age: lastProbeAge) }
        return .health(health, tally: tally)
    }

    var tone: OlcStatusTone {
        switch self {
        case .busy:             return .progress
        case .opFailed:         return .error
        // Grey, not red: "we could not check" is not a verdict about the server.
        case .unreachable:      return .unknown
        case .notChecked:       return .unknown
        case .probeFailed:      return .unknown   // #469
        case .containerStopped: return .warn
        case .noContainer(let b, _): return b.tone
        // Green when anything works, red only when everything checked failed;
        // a protocol that failed beside working ones is named by `problemLine`,
        // never averaged into the colour.
        case .health(let h, let t):
            let standing = t.standing(fallback: h)
            return standing == .unchecked && h.isChecking ? h.tone : standing.tone
        }
    }

    var title: String {
        switch self {
        case .busy(let verb, _, _, _): return "\(verb)…"
        // #456 (audit fix): name the operation that failed, not a generic sentence.
        case .opFailed(let verb, _):  return L10n.vpsOpFailed_fmt.formatted(verb)
        case .unreachable:        return L10n.vpsHeadlineUnreachable.localized()
        case .notChecked:         return L10n.vpsHeadlineNotChecked.localized()
        case .probeFailed:        return L10n.vpsHeadlineProbeFailed.localized()   // #469
        case .containerStopped:   return L10n.vpsHeadlineStopped.localized()
        case .noContainer(let b, _): return b.title
        case .health(let h, let t):
            let standing = t.standing(fallback: h)
            return standing == .unchecked && h.isChecking ? h.title : standing.title
        }
    }

    /// What failed, under a headline that says the server works: the protocols
    /// whose last check failed, in the warning colour. nil when none did.
    var problemLine: String? {
        if case .health(_, let t) = self { return t.problemLine }
        return nil
    }

    var subtitle: String {
        switch self {
        // #456 (audit fix): the live note plus "step n/total" — what the card
        // showed before the headline reducer existed.
        case .busy(_, let note, let step, let total):
            // #470: `step` is the 0-based phase while the bar draws
            // (phase + 1) / stepCount (`ServersView.statusBarFraction`), so the
            // pill read "0/3" over a third of a bar and topped out at "2/3"
            // under a full one. Same 1-based rendering as the bar (and as
            // LogsView's fetch phases).
            // #470 was: "\(step)/\(total)"
            let shown = min(step + 1, total)
            return note.isEmpty ? "\(shown)/\(total)" : "\(note) · \(shown)/\(total)"
        case .opFailed(_, let m): return m
        // No ages on the card: the app checks its servers when the screen
        // opens, so what the card says is from now.
        case .unreachable:        return L10n.vpsHeadlineUnreachableHintNever.localized()
        case .notChecked:         return L10n.vpsHeadlineNotCheckedHint.localized()
        case .probeFailed(let m): return m   // #469: the actual error, verbatim
        case .containerStopped:   return L10n.vpsHeadlineStoppedHint.localized()
        case .noContainer(let b, _): return b.subtitle
        // The tally IS the subtitle; without one, the verdict's own plain line.
        // A server carried only by its whole-server connection has no protocol
        // to count: it says it is connected.
        case .health(let h, let t):
            if t.working == 0, t.carriedLive { return L10n.stateConnected.localized() }
            // Every protocol is stopped: none is counted.
            if t.total == 0, !t.stopped.isEmpty { return L10n.protocolStoppedNote.localized() }
            guard t.total > 0 else { return h.plainLine }
            return L10n.vpsHeadlineProtocolsWorking_fmt.formatted(t.working, t.total)
        }
    }
}

// MARK: - Protocol rows ⇄ persisted snapshot (round 2, D)
//
// The Servers tab keeps its protocol rows (`SSHRunner.CarrierInfo`) in view
// state, which a cold start loses; the rows then appear only after the first
// SSH listing. These two pure conversions let the rows ride along in
// `HostSnapshot.carriers` (App/Models/NodeHealth.swift) so the first frame can
// draw them from memory. Pinned by `HostSnapshotTests`.
extension HostSnapshotCarrier {
    init(_ info: SSHRunner.CarrierInfo) {
        self.init(file: info.file, provider: info.provider, transport: info.transport,
                  room: info.room, container: info.container,
                  status: Self.rawStatus(info.status), isPrimary: info.isPrimary)
    }

    /// The row the Servers tab renders, status re-parsed from the raw text.
    var carrierInfo: SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(file: file, provider: provider, transport: transport,
                              room: room, container: container,
                              status: ContainerStatus.parse(from: status), isPrimary: isPrimary)
    }

    /// Inverse of `ContainerStatus.parse(from:)`: the text podman printed, or
    /// "" for a container that was not found.
    static func rawStatus(_ status: ContainerStatus) -> String {
        switch status {
        case .running(let s), .stopped(let s): return s
        case .notFound: return ""
        }
    }
}
