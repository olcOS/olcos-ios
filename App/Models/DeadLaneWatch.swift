import Foundation

/// Which lanes of a several-lane session have stayed out of their room for
/// `limit` without a break. The lane watch joins such a lane again and again,
/// but always in the room the session started with: when the server has moved
/// that protocol to another room meanwhile (a renewal, another phone, a new
/// list), no try can succeed, while the other lanes keep the session up and
/// nothing else notices. A lane named here makes the app look where the room
/// is now (TunnelManager.laneStayedDown). Fed on every look of the lane watch.
struct DeadLaneWatch {
    /// How long a lane may stay out of its room: the lane silence limit.
    static let limit: TimeInterval = LaneSilenceWatch.limit
    /// How long a lane still out after being named waits to be named again.
    static let again: TimeInterval = 10 * 60

    private var downSince: [TimeInterval?] = []
    private var nextAt: [TimeInterval?] = []

    /// `up`: each lane is in its room right now, in lane order. Returns the
    /// lanes due to be named; a different number of lanes starts over.
    mutating func deadLanes(up: [Bool], now: TimeInterval) -> [Int] {
        if downSince.count != up.count {
            downSince = Array(repeating: nil, count: up.count)
            nextAt = Array(repeating: nil, count: up.count)
        }
        var dead: [Int] = []
        for i in up.indices {
            if up[i] {
                downSince[i] = nil
                nextAt[i] = nil
                continue
            }
            let since = downSince[i] ?? now
            downSince[i] = since
            if now >= (nextAt[i] ?? since + Self.limit) {
                dead.append(i)
                nextAt[i] = now + Self.again
            }
        }
        return dead
    }
}
