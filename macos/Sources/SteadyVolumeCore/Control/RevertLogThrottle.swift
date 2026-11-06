import Foundation

/// Keeps revert logging readable: the first revert for a key is logged straight away, further
/// reverts inside the window are counted, and the count is reported once the window has passed.
/// Not thread-safe; used only from the enforcement thread.
public final class RevertLogThrottle {
    private final class Entry {
        var lastReported: Date
        var suppressed = 0
        init(lastReported: Date) { self.lastReported = lastReported }
    }

    private let now: () -> Date
    private let window: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(window: TimeInterval, now: @escaping () -> Date = Date.init) {
        precondition(window > 0)
        self.window = window
        self.now = now
    }

    /// Registers one event. Returns the number to report now (this one plus any suppressed
    /// earlier), or nil if it should be suppressed.
    public func register(_ key: String) -> Int? {
        let current = now()
        if let entry = entries[key], current.timeIntervalSince(entry.lastReported) < window {
            entry.suppressed += 1
            return nil
        }
        let count = (entries[key]?.suppressed ?? 0) + 1
        entries[key] = Entry(lastReported: current)
        return count
    }

    /// Returns and clears suppressed counts whose window has ended.
    public func drainExpired() -> [(key: String, count: Int)] {
        let current = now()
        var result: [(key: String, count: Int)] = []
        for (key, entry) in entries where entry.suppressed > 0 && current.timeIntervalSince(entry.lastReported) >= window {
            result.append((key, entry.suppressed))
            entry.suppressed = 0
            entry.lastReported = current
        }
        return result.sorted { $0.key < $1.key }
    }
}
