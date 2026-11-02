import Foundation

/// At most one run per `interval`, never two at once: the group refresh the leaderboard window starts when it appears
/// and when a group is picked (each run is three requests through the collector). Plain value, no SwiftUI: the unit
/// tests compile this file.
struct RefreshThrottle: Equatable {
    var interval: TimeInterval = 60
    private(set) var lastStart: Date?
    private(set) var running = false

    /// True when a run may start now; it then counts as started until `end()`.
    mutating func begin(now: Date = Date()) -> Bool {
        guard !running else { return false }
        if let last = lastStart, now.timeIntervalSince(last) < interval, last <= now {
            return false  // a clock set back makes `last` lie in the future: allow a run then instead of waiting
        }
        running = true
        lastStart = now
        return true
    }

    mutating func end() { running = false }
}
