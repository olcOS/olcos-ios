import Foundation
import Network

// MARK: - LaneBalancer
//
// Spreads one olcrtc tunnel's connections over several rooms of the same
// carrier ("lanes", OlcrtcConnection.extraRooms). Each lane is its own core
// runtime with its own loopback SOCKS listener. This listens on the port apps
// use and hands every NEW connection to the next lane that is up, byte for
// byte: the SOCKS handshake itself goes through to the lane, so credentials
// work unchanged. A single download still rides one room; a browser, Telegram
// or a speed test open several connections, and the rooms' speeds add up — a
// room's bitrate budget is per room (measured on a VPS: two SaluteJazz rooms
// carried twice what one did).
//
// A lane is skipped while its runtime is not running, and benched for a while
// after it twice in a row returns a connection that died with almost nothing
// sent back: a room that lost its server still accepts SOCKS, but every
// CONNECT through it fails. A lane whose own listener is gone (its connect
// refused, or "waiting", which on loopback never ends) is benched at once,
// and the connection that found it so is ended rather than left hanging.

/// Which lane takes the next connection. Pure → unit-tested.
struct LanePolicy {
    static let benchSeconds: TimeInterval = 20

    let count: Int
    private(set) var next = 0
    private(set) var failures: [Int]
    private(set) var benchedUntil: [Date?]

    init(count: Int) {
        self.count = max(1, count)
        failures = Array(repeating: 0, count: self.count)
        benchedUntil = Array(repeating: nil, count: self.count)
    }

    /// Round-robin over the lanes that are up and not benched; when none
    /// qualifies, over the ones that are up; when none is up, still in turn.
    mutating func pick(isUp: (Int) -> Bool, now: Date) -> Int {
        let order = (0..<count).map { (next + $0) % count }
        let rested = order.first { lane in
            guard isUp(lane) else { return false }
            guard let until = benchedUntil[lane] else { return true }
            return until <= now
        }
        let lane = rested ?? order.first(where: isUp) ?? order[0]
        next = (lane + 1) % count
        return lane
    }

    /// A connection on `lane` ended; `dead` when it looked like a dead room.
    mutating func record(lane: Int, dead: Bool, now: Date) {
        guard (0..<count).contains(lane) else { return }
        if dead {
            failures[lane] += 1
            if failures[lane] >= 2 {
                benchedUntil[lane] = now.addingTimeInterval(Self.benchSeconds)
                failures[lane] = 0
            }
        } else {
            failures[lane] = 0
            benchedUntil[lane] = nil
        }
    }

    /// The lane's listener is gone: set it aside now, not after two dead
    /// connections — every connection handed to it would hang meanwhile.
    mutating func setAside(lane: Int, now: Date) {
        guard (0..<count).contains(lane) else { return }
        failures[lane] = 0
        benchedUntil[lane] = now.addingTimeInterval(Self.benchSeconds)
    }

    /// Closed within a few seconds with no more than a SOCKS reply's worth
    /// of bytes back.
    static func looksDead(bytesBack: Int, duration: TimeInterval) -> Bool {
        bytesBack <= 32 && duration < 5
    }

    /// Whether the connection to a lane's loopback listener says that
    /// listener is gone: a loopback connect that is "waiting" (refused —
    /// Network then waits for a better path that never comes, and the
    /// connection would hang), or one that failed before anything came back.
    static func listenerGone(_ state: NWConnection.State, bytesBack: Int) -> Bool {
        switch state {
        case .waiting:
            return true
        case .failed:
            return bytesBack == 0
        case .setup, .preparing, .ready, .cancelled:
            return false
        @unknown default:
            return false
        }
    }
}

/// Bytes one lane has carried: toward the app (rx) and from it (tx).
struct LaneBytes: Equatable, Sendable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

final class LaneBalancer: @unchecked Sendable {

    enum StartError: Error {
        case portUnavailable(String)
    }

    private let queue = DispatchQueue(label: "olcos.lane-balancer")
    private let lanePorts: [UInt16]
    private let isUp: (Int) -> Bool
    private var policy: LanePolicy
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: LaneSession] = [:]
    /// What each lane has carried so far, toward the app (rx) and from it.
    private var carried: [LaneBytes]

    /// `isUp(i)` says whether lane `i`'s runtime is running; it is called on
    /// the balancer's own queue.
    init(lanePorts: [UInt16], isUp: @escaping (Int) -> Bool) {
        self.lanePorts = lanePorts
        self.isUp = isUp
        policy = LanePolicy(count: lanePorts.count)
        carried = Array(repeating: LaneBytes(), count: lanePorts.count)
    }

    /// What each lane has carried so far, in lane order.
    func laneBytes() -> [LaneBytes] {
        queue.sync { carried }
    }

    /// Listens on loopback `port`; throws when it cannot be bound.
    func start(port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw StartError.portUnavailable("port \(port)")
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.fire() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if gate.fire() { continuation.resume(throwing: StartError.portUnavailable(error.localizedDescription)) }
                case .cancelled:
                    if gate.fire() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        queue.sync { self.listener = listener }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let open = Array(sessions.values)
            sessions.removeAll()
            open.forEach { $0.cancel() }
        }
    }

    /// On `queue`.
    private func accept(_ client: NWConnection) {
        let lane = policy.pick(isUp: isUp, now: Date())
        guard let port = NWEndpoint.Port(rawValue: lanePorts[lane]) else { client.cancel(); return }
        let upstream = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let session = LaneSession(client: client, upstream: upstream, queue: queue)
        let id = ObjectIdentifier(session)
        session.onBytes = { [weak self] count, back in
            guard let self else { return }
            if back {
                self.carried[lane].rx &+= UInt64(count)
            } else {
                self.carried[lane].tx &+= UInt64(count)
            }
        }
        // By id, not by reference: the session owns this closure.
        session.onEnd = { [weak self] bytesBack, duration, listenerGone in
            guard let self else { return }
            if listenerGone {
                self.policy.setAside(lane: lane, now: Date())
            } else {
                self.policy.record(lane: lane,
                                   dead: LanePolicy.looksDead(bytesBack: bytesBack, duration: duration),
                                   now: Date())
            }
            self.sessions[id] = nil
        }
        sessions[id] = session
        session.start()
    }
}

/// One proxied connection: client ⇄ lane, until either side is done.
/// Every callback runs on the balancer's serial queue.
private final class LaneSession {
    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let started = Date()
    private var bytesBack = 0
    private var openDirections = 2
    private var finished = false
    /// Bytes sent back to the client, how long it lasted, and whether the
    /// lane's listener was gone (`LanePolicy.listenerGone`); called once.
    var onEnd: ((Int, TimeInterval, Bool) -> Void)?
    /// Every chunk passed on: its size, and whether it went back to the client.
    var onBytes: ((Int, Bool) -> Void)?

    init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        // A lane whose listener is gone leaves the upstream "waiting" for
        // good: end the connection, so the app tries again on another lane.
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if LanePolicy.listenerGone(state, bytesBack: self.bytesBack) {
                self.finish(listenerGone: true)
                return
            }
            switch state {
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        for connection in [client, upstream] {
            connection.start(queue: queue)
        }
        pump(from: client, to: upstream, countsBack: false)
        pump(from: upstream, to: client, countsBack: true)
    }

    func cancel() { finish() }

    private func pump(from source: NWConnection, to sink: NWConnection, countsBack: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                if countsBack { self.bytesBack += data.count }
                self.onBytes?(data.count, countsBack)
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.finished else { return }
                    if sendError != nil {
                        self.finish()
                    } else if isComplete {
                        self.closeDirection(sink)
                    } else {
                        self.pump(from: source, to: sink, countsBack: countsBack)
                    }
                })
            } else if error != nil {
                self.finish()
            } else if isComplete {
                self.closeDirection(sink)
            } else {
                self.pump(from: source, to: sink, countsBack: countsBack)
            }
        }
    }

    /// One side finished sending: pass the end on, and finish once both have.
    private func closeDirection(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in })
        openDirections -= 1
        if openDirections == 0 { finish() }
    }

    private func finish(listenerGone: Bool = false) {
        guard !finished else { return }
        finished = true
        client.cancel()
        upstream.cancel()
        let end = onEnd
        onEnd = nil
        onBytes = nil
        end?(bytesBack, Date().timeIntervalSince(started), listenerGone)
    }
}
