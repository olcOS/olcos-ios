import Foundation

// MARK: - BestServerSearch
//
// Finds a working server among many, the way a list of free servers needs: a
// TCP connect to every server at once ranks them by how fast they answer, then
// the full check (a real request through the server) runs on the fastest few,
// one after another, until one passes. With a session up the full check would
// measure through the live tunnel, so the fastest server that answered the
// knock is taken instead.

@MainActor
final class BestServerSearch: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Knocking on every server.
        case knocking(total: Int)
        /// The full check on the `index`-th of the fastest `of`.
        case checking(index: Int, of: Int)
        /// No server passed.
        case noneFound
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    /// How many of the fastest servers get the full check.
    static let fullChecks = 5
    /// Servers knocked on at once.
    static let parallelKnocks = 16

    var isRunning: Bool {
        switch phase {
        case .knocking, .checking: return true
        case .idle, .noneFound:    return false
        }
    }

    func start(_ records: [ConnectionRecord], tunnel: TunnelManager, health: HealthCoordinator,
               found: @escaping @MainActor (ConnectionRecord) -> Void) {
        task?.cancel()
        let candidates = records.filter { Self.endpoint(of: $0) != nil }
        guard !candidates.isEmpty else { phase = .noneFound; return }
        phase = .knocking(total: candidates.count)
        task = Task { [weak self] in
            let answers = await Self.knock(candidates)
            guard let self, !Task.isCancelled else { return }
            let order = Self.ranked(answers)
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sessionUp = tunnel.state.isConnected || tunnel.state.isConnecting
            if sessionUp {
                if let first = order.first, let record = byID[first] {
                    self.phase = .idle
                    found(record)
                } else {
                    self.phase = .noneFound
                }
                return
            }
            let shortlist = Array(order.prefix(Self.fullChecks))
            for (index, id) in shortlist.enumerated() {
                guard let record = byID[id], !Task.isCancelled else { return }
                self.phase = .checking(index: index + 1, of: shortlist.count)
                if await health.verify(record, using: tunnel, force: true).isVerified {
                    guard !Task.isCancelled else { return }
                    self.phase = .idle
                    found(record)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.phase = .noneFound
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// The server a record dials directly; nil for a call protocol, whose
    /// rendezvous is a conference service, not the server itself.
    nonisolated static func endpoint(of record: ConnectionRecord) -> (host: String, port: UInt16)? {
        guard case .xray(let p) = record.details, let port = UInt16(exactly: p.port) else { return nil }
        return (p.host, port)
    }

    /// PURE. The servers that answered, fastest first; ties keep the list order.
    nonisolated static func ranked(_ answers: [(id: UUID, ms: Double?)]) -> [UUID] {
        answers.enumerated()
            .compactMap { offset, answer in answer.ms.map { (offset: offset, id: answer.id, ms: $0) } }
            .sorted { $0.ms != $1.ms ? $0.ms < $1.ms : $0.offset < $1.offset }
            .map(\.id)
    }

    /// One TCP connect per server, `parallelKnocks` at a time.
    private nonisolated static func knock(_ records: [ConnectionRecord]) async -> [(id: UUID, ms: Double?)] {
        let targets: [(id: UUID, host: String, port: UInt16)] = records.compactMap { record in
            endpoint(of: record).map { (id: record.id, host: $0.host, port: $0.port) }
        }
        var results: [(id: UUID, ms: Double?)] = targets.map { (id: $0.id, ms: nil) }
        await withTaskGroup(of: (Int, Double?).self) { group in
            var next = 0
            while next < min(parallelKnocks, targets.count) {
                let (index, target) = (next, targets[next])
                group.addTask {
                    let answer = await NetPing.tcp(host: target.host, port: target.port, timeout: 3)
                    return (index, answer.success ? answer.ms : nil)
                }
                next += 1
            }
            while let (index, ms) = await group.next() {
                results[index].ms = ms
                if next < targets.count {
                    let (nextIndex, target) = (next, targets[next])
                    group.addTask {
                        let answer = await NetPing.tcp(host: target.host, port: target.port, timeout: 3)
                        return (nextIndex, answer.success ? answer.ms : nil)
                    }
                    next += 1
                }
            }
        }
        return results
    }
}
