import SwiftUI

/// Runs `SSHRunner.checkJitsiInstances` for a sheet and keeps what each Jitsi
/// service did. The sheet owns it (`@StateObject`) and starts it when Jitsi is
/// the chosen carrier.
@MainActor
final class JitsiInstanceCheck: ObservableObject {
    typealias Run = @MainActor (_ candidates: [String], _ transport: String,
                                _ onResult: @escaping @MainActor (JitsiTunnelCheck) -> Void) async throws -> Void

    @Published private(set) var verdicts: [String: JitsiTunnelCheck.Verdict] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var failure: String?
    /// Row order: the list order while checking; working services, fastest
    /// first, once a check has ended.
    @Published private(set) var order: [String] = []
    /// The service the last check switched to on its own.
    @Published private(set) var autoPicked: String?
    /// Set when the user picks or types a service: a check then never switches.
    var userPicked = false

    private var task: Task<Void, Never>?

    /// `current` is the service the sheet starts with (listed and checked even
    /// when it is not a known one). When the check ends and `current` did not
    /// work, `choose` gets the fastest service that did.
    func start(_ run: @escaping Run, current: String?, transport: String,
               choose: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        let candidates = Self.candidates(current: current)
        order = candidates
        verdicts = [:]
        failure = nil
        autoPicked = nil
        isRunning = true
        task = Task { [weak self] in
            do {
                try await run(candidates, transport) { result in
                    self?.verdicts[result.host] = result.verdict
                }
            } catch {
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            guard !Task.isCancelled, let self else { return }
            self.isRunning = false
            self.order = Self.sorted(candidates, by: self.verdicts)
            if !self.userPicked,
               let pick = Self.autoPick(current: current, verdicts: self.verdicts, order: candidates) {
                self.autoPicked = pick
                choose(pick)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    nonisolated static func candidates(current: String?) -> [String] {
        var list = CarrierEndpoints.jitsiInstances
        if let current, !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    /// PURE. Working services first, fastest first; then the rest from the one
    /// that came closest to working; ties keep the list order.
    nonisolated static func sorted(_ hosts: [String],
                                   by verdicts: [String: JitsiTunnelCheck.Verdict]) -> [String] {
        func rank(_ verdict: JitsiTunnelCheck.Verdict?) -> (Int, Int) {
            switch verdict {
            case .some(.works(let bytesPerSecond)): return (0, -bytesPerSecond)
            case .some(.answers):                   return (1, 0)
            case .none:                             return (2, 0)
            case .some(.stalls):                    return (3, 0)
            case .some(.noData):                    return (4, 0)
            case .some(.needsLogin):                return (5, 0)
            case .some(.unreachable):               return (6, 0)
            }
        }
        return hosts.enumerated().sorted { a, b in
            let (ra, rb) = (rank(verdicts[a.element]), rank(verdicts[b.element]))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// PURE. The service to switch to when a check ends: the fastest working
    /// one, unless the current service works.
    nonisolated static func autoPick(current: String?, verdicts: [String: JitsiTunnelCheck.Verdict],
                                     order: [String]) -> String? {
        if let current, verdicts[current]?.works == true { return nil }
        return sorted(order, by: verdicts).first { verdicts[$0]?.works == true }
    }

    /// The words under a service's name.
    static func detail(_ verdict: JitsiTunnelCheck.Verdict?, running: Bool) -> String? {
        switch verdict {
        case .some(.works(let bytesPerSecond)):
            return L10n.jitsiCheckWorks_fmt.formatted(ThroughputFormat.bits(Double(bytesPerSecond)))
        case .some(.stalls):      return L10n.jitsiCheckStalls.localized()
        case .some(.noData):      return L10n.jitsiCheckNoData.localized()
        case .some(.unreachable): return L10n.jitsiCheckUnreachable.localized()
        case .some(.needsLogin):  return L10n.jitsiCheckNeedsLogin.localized()
        case .some(.answers):     return L10n.jitsiCheckAnswers.localized()
        case .none:               return running ? L10n.jitsiCheckRunning.localized() : nil
        }
    }
}

/// The Jitsi service part of a sheet's Form: one row per public service with
/// what the user's server found when it tried it, a button to check again and
/// a field for an address of the user's own.
struct JitsiInstanceSection: View {
    @Binding var baseURL: String
    @ObservedObject var check: JitsiInstanceCheck
    /// nil where there is no installed server to try the services from.
    let rerun: (() -> Void)?

    private var currentHost: String {
        CarrierEndpoints.host(fromRoomID: baseURL) ?? baseURL
    }

    private var selection: Binding<String> {
        Binding(get: { currentHost },
                set: {
                    check.userPicked = true
                    baseURL = CarrierEndpoints.jitsiBaseURL(forInstance: $0)
                })
    }

    private var customAddress: Binding<String> {
        Binding(get: { baseURL },
                set: {
                    check.userPicked = true
                    baseURL = $0
                })
    }

    private var rows: [String] {
        check.order.isEmpty ? JitsiInstanceCheck.candidates(current: currentHost) : check.order
    }

    private var details: [String: String] {
        var out: [String: String] = [:]
        for host in rows {
            if let text = JitsiInstanceCheck.detail(check.verdicts[host], running: check.isRunning) {
                out[host] = text
            }
        }
        return out
    }

    private var noneWorks: Bool {
        !check.isRunning && !check.verdicts.isEmpty && !check.verdicts.values.contains { $0.works }
    }

    var body: some View {
        Section {
            if let failure = check.failure {
                FormNote(text: L10n.jitsiCheckFailed_fmt.formatted(failure), tone: .warn)
                    .listRowSeparator(.hidden)
            } else if noneWorks {
                FormNote(text: L10n.jitsiCheckNoneWorks.localized(), tone: .warn)
                    .listRowSeparator(.hidden)
            } else if let picked = check.autoPicked, picked == currentHost {
                FormNote(text: L10n.jitsiCheckPickedFastest_fmt.formatted(picked), tone: .ok)
                    .listRowSeparator(.hidden)
            } else if check.isRunning {
                FormNote(text: L10n.jitsiCheckNote.localized())
                    .listRowSeparator(.hidden)
            }
            ServerSignalOptions(selection: selection,
                                options: rows.map { ($0, $0) },
                                details: details)
            if let rerun {
                Button(action: rerun) {
                    Label(check.isRunning ? L10n.jitsiCheckRunning.localized() : L10n.jitsiCheckAgain.localized(),
                          systemImage: "arrow.clockwise")
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Signal.stroke)
                        .frame(minHeight: Theme.Metrics.controlHeight)
                }
                .buttonStyle(.plain)
                .disabled(check.isRunning)
            }
            FormField(label: L10n.addFlowJitsiCustom.localized(),
                      placeholder: L10n.fieldJitsiURL.localized(),
                      text: customAddress, keyboard: .URL, mono: true,
                      helper: L10n.jitsiCustomHelper.localized())
        } header: {
            SignalSectionHeader(L10n.jitsiCheckSectionHeader.localized())
        }
        .signalFormRows()
    }
}
