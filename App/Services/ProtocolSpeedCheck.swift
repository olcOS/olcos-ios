import Foundation

// MARK: - ProtocolSpeedCheck
//
// While a session runs over several rooms, each room keeps its own loopback
// SOCKS listener behind the one apps use (OlcrtcEngine.lanePorts). This check
// goes through each of them in turn — round trip, download speed, the address
// the internet sees — and then through the shared port, where every room
// carries the download at once. Side by side the rows answer the question a
// speed test app cannot: does each protocol work, which is fastest, and does
// joining them add speed. Nothing reconnects; the live session is measured as
// it is.

@MainActor
final class ProtocolSpeedCheck: ObservableObject {

    /// Where one measurement goes: a lane's own port, or the shared one.
    struct Target: Equatable {
        /// The lane's place, or `ProtocolSpeedCheck.allTogether`.
        let id: Int
        let name: String
        let port: Int
    }

    struct Row: Identifiable, Equatable {
        /// `reconnecting`: the room's own listener did not answer — its runtime
        /// is joining the room again, so there is nothing to measure yet.
        enum Phase: Equatable { case idle, waiting, measuring, done, failed, reconnecting }

        let id: Int
        let name: String
        var phase: Phase = .idle
        var pingMs: Int?
        var bytesPerSecond: Double?
        /// The exit as a line: "🇳🇱 Amsterdam, NL · 203.0.113.7".
        var exit: String?
        /// The download speed every quarter second while it runs, for the graph.
        var samples: [Double] = []
    }

    static let allTogether = -1
    /// How long one download runs at most, and how much it fetches at most.
    static let downloadSeconds: TimeInterval = 8
    static let downloadURL = "https://speed.cloudflare.com/__down?bytes=50000000"
    static let pingURL = "https://cp.cloudflare.com/generate_204"

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    /// Shows the rows a check would fill, keeping results of the same targets.
    func prepare(_ targets: [Target]) {
        guard !isRunning else { return }
        let old = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = targets.map { target in
            if let kept = old[target.id], kept.name == target.name { return kept }
            return Row(id: target.id, name: target.name)
        }
    }

    /// Measures `targets` one after another; the other rows keep their
    /// results. `credentials` are the live session's SOCKS login, shared by
    /// every port.
    func run(_ targets: [Target], credentials: (user: String, pass: String)?) {
        cancel()
        for target in targets {
            let fresh = Row(id: target.id, name: target.name, phase: .waiting)
            if let i = rows.firstIndex(where: { $0.id == target.id }) {
                rows[i] = fresh
            } else {
                rows.append(fresh)
            }
        }
        isRunning = true
        // A long transfer is the tunnel at work: keep-alive need not probe it.
        SOCKSSession.noteTunnelActivity(forAtLeast: Double(targets.count) * (Self.downloadSeconds + 12))
        task = Task { [weak self] in
            for target in targets {
                guard let self, !Task.isCancelled else { return }
                await self.measure(target, credentials: credentials)
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    /// Tests and screenshots: show these rows as they are.
    func _showForTesting(_ rows: [Row]) {
        self.rows = rows
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { isRunning = false }
        for row in rows where row.phase == .waiting || row.phase == .measuring {
            update(row.id) { $0.phase = .idle }
        }
    }

    /// PURE. The fastest single lane among the results, by download.
    static func fastestLane(_ rows: [Row]) -> Row? {
        rows.filter { $0.id != allTogether && $0.phase == .done && ($0.bytesPerSecond ?? 0) > 0 }
            .max { ($0.bytesPerSecond ?? 0) < ($1.bytesPerSecond ?? 0) }
    }

    /// PURE. How many times the bonded download beats the fastest lane alone;
    /// nil until both were measured.
    static func gain(_ rows: [Row]) -> Double? {
        guard let together = rows.first(where: { $0.id == allTogether && $0.phase == .done })?.bytesPerSecond,
              let best = fastestLane(rows)?.bytesPerSecond, best > 0 else { return nil }
        return together / best
    }

    // MARK: One target

    private func measure(_ target: Target, credentials: (user: String, pass: String)?) async {
        update(target.id) { $0.phase = .measuring }
        // A port nobody listens on is not "no answer": URLSession would go
        // around a refusing proxy and measure the phone's own connection.
        guard await TunnelManager.socksListenerAnswers(port: target.port) else {
            update(target.id) { $0.phase = .reconnecting }
            return
        }
        let session = Self.session(port: target.port, credentials: credentials)
        defer { session.invalidateAndCancel() }

        let ping = await Self.roundTrip(session)
        guard !Task.isCancelled else { return }
        update(target.id) { $0.pingMs = ping }

        let download = ProgressDownload(session: session)
        let rate = await download.run(url: URL(string: Self.downloadURL)!, seconds: Self.downloadSeconds) { [weak self] speed in
            self?.update(target.id) { $0.samples.append(speed) }
        }
        guard !Task.isCancelled else { return }
        update(target.id) { $0.bytesPerSecond = rate }

        let exit = await IPChecker.fetchExitGeo(session: session).map { IPChecker.exitGeoLine($0) }
        guard !Task.isCancelled else { return }
        update(target.id) {
            $0.exit = exit
            $0.phase = (ping == nil && (rate ?? 0) <= 0) ? .failed : .done
        }
        if (rate ?? 0) > 0 { SOCKSSession.noteTunnelActivity() }
    }

    private func update(_ id: Int, _ change: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[i]
        change(&row)
        if row != rows[i] { rows[i] = row }
    }

    private static func session(port: Int, credentials: (user: String, pass: String)?) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = downloadSeconds + 20
        cfg.connectionProxyDictionary = SOCKSSession.proxyDictionary(port: port, credentials: credentials)
        return URLSession(configuration: cfg)
    }

    /// The best of three round trips to a tiny page, in milliseconds.
    private static func roundTrip(_ session: URLSession) async -> Int? {
        guard let url = URL(string: pingURL) else { return nil }
        var best: TimeInterval?
        for _ in 0..<3 {
            guard !Task.isCancelled else { return nil }
            let start = Date()
            guard let answer = try? await session.data(from: url),
                  let http = answer.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { continue }
            let elapsed = Date().timeIntervalSince(start)
            best = min(best ?? elapsed, elapsed)
        }
        return best.map { Int(($0 * 1000).rounded()) }
    }
}

// MARK: - ProgressDownload

/// Downloads for at most `seconds`, reporting the speed every quarter second;
/// returns the average in bytes per second, or nil when nothing arrived.
final class ProgressDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var received: Int64 = 0

    init(session: URLSession) {
        self.session = session
    }

    @MainActor
    func run(url: URL, seconds: TimeInterval, onSample: @escaping (Double) -> Void) async -> Double? {
        let task = session.dataTask(with: url)
        task.delegate = self
        let start = Date()
        task.resume()
        var lastBytes: Int64 = 0
        var lastAt = start
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let now = Date()
            let bytes = lock.withLock { received }
            let dt = now.timeIntervalSince(lastAt)
            if dt > 0 { onSample(Double(bytes - lastBytes) / dt) }
            lastBytes = bytes
            lastAt = now
            let done = task.state == .completed
            if done || now.timeIntervalSince(start) >= seconds { break }
        }
        task.cancel()
        let elapsed = Date().timeIntervalSince(start)
        let total = lock.withLock { received }
        guard total > 0, elapsed > 0 else { return nil }
        return Double(total) / elapsed
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received += Int64(data.count) }
    }
}
