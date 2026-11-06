import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tunnel throughput (hero picture intensity + spoken rate)
//
// The hero picture's traffic particles flow with real traffic; the measured
// rate is spoken to VoiceOver (VPN: ↓/↑; SOCKS5: one "about" figure), never
// printed. Two data sources, both documented in docs/architecture.md:
//
//   • VPN mode — EXACT. `Tunnel/PacketTunnelProvider.swift` answers the
//     "stats" provider message with cumulative tunstack counters (`rxBytes`
//     toward the device, `txBytes` from the device, `v` = 1). The app polls
//     them ~1/s through `VPNController.stats()` while connected and on screen.
//   • SOCKS5 in-app mode — APPROXIMATE. Upstream's `mobile.Runtime` exposes no
//     byte counters (internal/client/tunnel.go discards CopyBidirectional's
//     counts), and adding some would mean patching the submodule. Instead the
//     app reads the loopback interface (`lo0`) byte counters via getifaddrs
//     and takes deltas while the local SOCKS5 listener is active. Every byte
//     a local client exchanges with the listener crosses lo0 once, so the
//     delta is a fair proxy for total tunnelled traffic — but it cannot be
//     split into ↓/↑ and includes any other loopback traffic on the device.
//     The readout therefore shows ONE figure marked "≈".
//
// Nothing here invents numbers: no sample → no reading → nothing spoken, and
// the picture falls back to its calm idle drift.

/// Cumulative byte counters observed at one instant of a monotonic clock.
struct ThroughputCounters: Equatable {
    /// Bytes toward the device (↓). For the loopback estimate: lo0 input bytes.
    var inBytes: UInt64
    /// Bytes from the device (↑). For the loopback estimate: equals `inBytes`.
    var outBytes: UInt64
    /// Monotonic seconds (provider or process uptime), never wall-clock.
    var at: TimeInterval
}

/// A smoothed rate for the readout and the waveform.
enum ThroughputReading: Equatable {
    /// Exact packet-path counters (VPN mode).
    case exact(inBytesPerSecond: Double, outBytesPerSecond: Double)
    /// Loopback estimate (SOCKS5 in-app mode): one undirected figure.
    case estimate(totalBytesPerSecond: Double)

    var totalBytesPerSecond: Double {
        switch self {
        case .exact(let i, let o): return i + o
        case .estimate(let t):     return t
        }
    }

    var isExact: Bool {
        if case .exact = self { return true }
        return false
    }

    /// 0…1 part of the traffic flowing toward the device. Exact counters
    /// split it; the undirected estimate (and a silent tunnel) report 0.5.
    var inboundShare: Double {
        switch self {
        case .exact(let i, let o):
            let total = i + o
            guard total.isFinite, total > 0, i.isFinite, i >= 0 else { return 0.5 }
            return min(1, max(0, i / total))
        case .estimate:
            return 0.5
        }
    }
}

/// One lane's smoothed rate.
struct LaneReading: Equatable, Identifiable {
    /// The lane's place in the engine's order.
    let id: Int
    let name: String
    var inBytesPerSecond: Double
    var outBytesPerSecond: Double
    /// false: the room is still being joined, or joined again after it dropped out.
    var isUp = true

    /// PURE. The lane's name, numbered when another lane has the same one
    /// ("Jitsi", "Jitsi 2"); a lane past the known names is "Lane N".
    static func name(at index: Int, in names: [String]) -> String {
        guard names.indices.contains(index) else { return L10n.laneUnnamed_fmt.formatted(index + 1) }
        let name = names[index]
        let same = names.indices.filter { names[$0] == name }
        guard same.count > 1, let place = same.firstIndex(of: index), place > 0 else { return name }
        return "\(name) \(place + 1)"
    }

    /// The live session's lanes as the engine counts them, by service; empty
    /// for one room. A VPN bonds the lanes VPNConfig hands the extension.
    static func names(of record: ConnectionRecord?, inVPN: Bool = false) -> [String] {
        guard case .olcrtc(let params)? = record?.details, params.lanes.count > 1 else { return [] }
        var lanes = params.lanes
        if inVPN {
            lanes = VPNConfig.bondedLanes(lanes)
        }
        return lanes.map { CarrierTransportMatrix.carrierLabel($0.carrier) }
    }

    /// PURE. Each lane's part of the download, 0…1, for the bars.
    static func shares(_ lanes: [LaneReading]) -> [Int: Double] {
        let total = lanes.reduce(0) { $0 + max(0, $1.inBytesPerSecond) }
        guard total > 0 else { return Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, 0) }) }
        return Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, max(0, $0.inBytesPerSecond) / total) })
    }
}

/// Exponential moving average over cumulative counters. Pure; testable.
struct ThroughputEstimator: Equatable {
    /// EMA time constant in seconds: 1 Hz samples settle in ~3 samples.
    static let timeConstant: TimeInterval = 2.0

    private(set) var inBytesPerSecond = 0.0
    private(set) var outBytesPerSecond = 0.0
    private var last: ThroughputCounters?

    /// Feeds one sample. Returns nil until two ordered samples exist. A
    /// counter that went backwards (tunnel restarted) resets the average.
    mutating func ingest(_ sample: ThroughputCounters) -> (inBytesPerSecond: Double, outBytesPerSecond: Double)? {
        guard let previous = last else {
            last = sample
            return nil
        }
        last = sample
        let dt = sample.at - previous.at
        guard dt.isFinite, dt > 0 else { return nil }
        guard sample.inBytes >= previous.inBytes, sample.outBytes >= previous.outBytes else {
            inBytesPerSecond = 0
            outBytesPerSecond = 0
            return nil
        }
        let instantIn = Double(sample.inBytes - previous.inBytes) / dt
        let instantOut = Double(sample.outBytes - previous.outBytes) / dt
        let weight = 1 - exp(-dt / Self.timeConstant)
        inBytesPerSecond += (instantIn - inBytesPerSecond) * weight
        outBytesPerSecond += (instantOut - outBytesPerSecond) * weight
        return (inBytesPerSecond, outBytesPerSecond)
    }

    mutating func reset() {
        self = ThroughputEstimator()
    }
}

/// Extends a 32-bit interface counter (`if_data.ifi_ibytes` wraps at 4 GiB)
/// into a monotonic 64-bit value. Pure; testable.
struct WrappingCounter32: Equatable {
    private var previous: UInt32?
    private(set) var total: UInt64 = 0

    mutating func extend(_ value: UInt32) -> UInt64 {
        if let previous {
            total &+= UInt64(value &- previous)
        }
        previous = value
        return total
    }
}

/// Human figures for the readout, the way speed tests count: bits. The unit
/// strings are localized; digits use the current locale's separator.
enum ThroughputFormat {
    /// In bits, as a speed test counts: "0 Kbit/s" … "999 Kbit/s", "4.5 Mbit/s",
    /// "120 Mbit/s" (decimal kilo and mega, like every speed test).
    static func bits(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) * 8 : 0
        if value < 1_000_000 {
            return L10n.throughputKbit_fmt.formatted(number((value / 1_000).rounded(), fractionDigits: 0,
                                                            locale: locale))
        }
        let mbit = value / 1_000_000
        return L10n.throughputMbit_fmt.formatted(number(mbit, fractionDigits: mbit < 100 ? 1 : 0, locale: locale))
    }

    /// The narrowest form, for the Dynamic Island's corner: "850K", "4.5M".
    static func bitsShort(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) * 8 : 0
        if value < 1_000_000 {
            return L10n.throughputShortKbit_fmt.formatted(number((value / 1_000).rounded(), fractionDigits: 0,
                                                                 locale: locale))
        }
        let mbit = value / 1_000_000
        return L10n.throughputShortMbit_fmt.formatted(number(mbit, fractionDigits: mbit < 10 ? 1 : 0,
                                                             locale: locale))
    }

    /// Locale decimal separator, no thousands grouping: "1023", "1.2" / "1,2".
    /// (`String(format:locale:)` groups — "1,023 KB/s" — which reads as a
    /// decimal in half the locales this app ships in.)
    static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let plain = String(format: "%.\(fractionDigits)f", value)   // C locale: "." and no grouping
        guard fractionDigits > 0, let separator = locale.decimalSeparator, separator != "." else { return plain }
        return plain.replacingOccurrences(of: ".", with: separator)
    }
}

// MARK: - Sources

/// Loopback (`lo0`) byte counters from getifaddrs, extended to 64 bits.
/// Device-wide, not per process; direction is meaningless on loopback.
struct LoopbackCounterReader {
    static let interfaceName = "lo0"
    private var inCounter = WrappingCounter32()
    private var outCounter = WrappingCounter32()

    #if canImport(Darwin)
    /// Raw 32-bit interface counters, or nil when the interface is not listed.
    static func rawCounters(interface: String = interfaceName) -> (inBytes: UInt32, outBytes: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var result: (inBytes: UInt32, outBytes: UInt32)?
        while let node = cursor {
            let entry = node.pointee
            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data,
               String(cString: entry.ifa_name) == interface {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                result = (stats.ifi_ibytes, stats.ifi_obytes)
                break
            }
            cursor = entry.ifa_next
        }
        return result
    }
    #else
    static func rawCounters(interface: String = interfaceName) -> (inBytes: UInt32, outBytes: UInt32)? { nil }
    #endif

    mutating func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ThroughputCounters? {
        guard let raw = Self.rawCounters() else { return nil }
        return ThroughputCounters(inBytes: inCounter.extend(raw.inBytes),
                                  outBytes: outCounter.extend(raw.outBytes),
                                  at: now)
    }

    mutating func reset() {
        self = LoopbackCounterReader()
    }
}

// MARK: - Monitor

/// Polls the active backend ~1/s and publishes a smoothed reading. Runs only
/// while the caller says the tunnel is connected AND the hero is on screen in
/// the foreground; `update` with anything else cancels the loop and clears the
/// reading so no stale figure survives a disconnect or a mode change.
@MainActor
final class TunnelThroughputMonitor: ObservableObject {
    @Published private(set) var reading: ThroughputReading?
    /// Each lane's own rate while a session runs over several (extra rooms, a
    /// whole server); empty for one room. Its sum is the exact `reading`.
    @Published private(set) var lanes: [LaneReading] = []

    /// What the session moved since this monitor started on it: ↓ and ↑, or
    /// (`exact` false, the loopback estimate) one figure for both ways.
    struct SessionBytes: Equatable {
        var down: UInt64
        var up: UInt64
        var exact: Bool
    }
    @Published private(set) var sessionBytes: SessionBytes?
    /// The last counters seen, to add up the next sample's difference.
    private var lastCounters: ThroughputCounters?

    static let pollInterval: Duration = .seconds(1)

    /// How often this monitor samples. The hero wants `pollInterval` for a
    /// smooth waveform; the Live Activity card updates at most every 2 s, so it
    /// samples at that pace — faster only costs battery while the app runs in
    /// the background, and in VPN mode every sample is a call into the tunnel
    /// extension.
    private let interval: Duration

    private var task: Task<Void, Never>?
    private var runningMode: TunnelMode?
    private var estimator = ThroughputEstimator()
    private var loopback = LoopbackCounterReader()
    private var laneEstimators: [ThroughputEstimator] = []
    /// The lanes' names, in the order the engine counts them.
    private var laneNames: [String] = []
    /// Where the lanes' byte counts come from; nil when there are none.
    private let laneSource: @Sendable () -> [LaneBytes]?
    private let laneReady: @Sendable () -> [Bool]?

    init(interval: Duration = .seconds(1),
         laneSource: @escaping @Sendable () -> [LaneBytes]? = { OlcrtcEngine.shared.laneBytes() },
         laneReady: @escaping @Sendable () -> [Bool]? = { OlcrtcEngine.shared.laneReady() }) {
        self.interval = interval
        self.laneSource = laneSource
        self.laneReady = laneReady
    }

    /// Smoothed total for the waveform (0 when there is no reading).
    var intensity: Double {
        SignalMotionPolicy.intensity(bytesPerSecond: reading?.totalBytesPerSecond ?? 0)
    }

    /// `laneNames`: the live session's lanes, in the engine's order (empty
    /// for one room).
    func update(isConnected: Bool, isOnScreen: Bool, sceneIsActive: Bool,
                mode: TunnelMode, vpn: VPNController, laneNames: [String] = []) {
        let shouldRun = isConnected && isOnScreen && sceneIsActive
        guard shouldRun else { stop(); return }
        if laneNames != self.laneNames {
            self.laneNames = laneNames
            resetLanes()
        }
        if task != nil, runningMode == mode { return }
        stop()
        self.laneNames = laneNames
        runningMode = mode
        let pace = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                var sample: ThroughputCounters?
                var exact = false
                switch mode {
                case .vpn:
                    let stats = await Self.packetTunnelStats(vpn)
                    sample = stats.counters
                    // A session bonded inside the extension reports its lanes too.
                    if let lanes = stats.lanes, !lanes.isEmpty { self?.applyLanes(lanes, at: now) }
                    exact = true
                case .proxy:
                    // Several lanes: their own counts, exact and per lane.
                    // One room: the loopback estimate.
                    if let counts = self?.laneSource(), !counts.isEmpty {
                        self?.applyLanes(counts, at: now, ready: self?.laneReady())
                        sample = ThroughputCounters(inBytes: counts.reduce(0) { $0 &+ $1.rx },
                                                    outBytes: counts.reduce(0) { $0 &+ $1.tx }, at: now)
                        exact = true
                    } else {
                        sample = self?.loopback.sample(now: now) ?? nil
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.apply(sample, exact: exact)
                try? await Task.sleep(for: pace)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        runningMode = nil
        estimator.reset()
        loopback.reset()
        resetLanes()
        if reading != nil { reading = nil }
        lastCounters = nil
        if sessionBytes != nil { sessionBytes = nil }
    }

    /// Adds what moved since the last sample. Counters that went back (a lane
    /// started over) count from zero again rather than subtract.
    private func accumulate(_ sample: ThroughputCounters, exact: Bool) {
        defer { lastCounters = sample }
        var next = sessionBytes ?? SessionBytes(down: 0, up: 0, exact: exact)
        if let last = lastCounters {
            next.down &+= sample.inBytes >= last.inBytes ? sample.inBytes - last.inBytes : sample.inBytes
            next.up &+= sample.outBytes >= last.outBytes ? sample.outBytes - last.outBytes : sample.outBytes
        }
        next.exact = exact
        if next != sessionBytes { sessionBytes = next }
    }

    private func resetLanes() {
        laneEstimators = []
        if !lanes.isEmpty { lanes = [] }
    }

    private func apply(_ sample: ThroughputCounters?, exact: Bool) {
        if let sample { accumulate(sample, exact: exact) }
        guard let sample, let rates = estimator.ingest(sample) else {
            if sample == nil, reading != nil { reading = nil }
            return
        }
        // lo0 input == lo0 output byte-for-byte: the estimate is one figure.
        let next: ThroughputReading = exact
            ? .exact(inBytesPerSecond: rates.inBytesPerSecond, outBytesPerSecond: rates.outBytesPerSecond)
            : .estimate(totalBytesPerSecond: rates.inBytesPerSecond)
        if next != reading { reading = next }
    }

    /// Feeds one count per lane; a lane list that changed length starts over.
    private func applyLanes(_ counts: [LaneBytes], at now: TimeInterval, ready: [Bool]? = nil) {
        if laneEstimators.count != counts.count {
            laneEstimators = Array(repeating: ThroughputEstimator(), count: counts.count)
        }
        var next: [LaneReading] = []
        for (i, count) in counts.enumerated() {
            let rates = laneEstimators[i].ingest(ThroughputCounters(inBytes: count.rx, outBytes: count.tx, at: now))
            next.append(LaneReading(id: i, name: LaneReading.name(at: i, in: laneNames),
                                    inBytesPerSecond: rates?.inBytesPerSecond ?? 0,
                                    outBytesPerSecond: rates?.outBytesPerSecond ?? 0,
                                    isUp: ready.map { i < $0.count ? $0[i] : true } ?? true))
        }
        if next != lanes { lanes = next }
    }

    private static func packetTunnelStats(_ vpn: VPNController) async
        -> (counters: ThroughputCounters?, lanes: [LaneBytes]?) {
        guard let data = await vpn.stats(),
              let stats = VPNController.ProviderStats.decode(data),
              let rx = stats.rxBytes, let tx = stats.txBytes else { return (nil, nil) }
        let at = stats.monotonicMs.map { Double($0) / 1000 } ?? ProcessInfo.processInfo.systemUptime
        return (ThroughputCounters(inBytes: UInt64(max(0, rx)), outBytes: UInt64(max(0, tx)), at: at),
                stats.laneBytes.flatMap(OlcrtcEngine.parseLaneBytes))
    }
}
