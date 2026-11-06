import Foundation

/// After `maxAttempts` consecutive wrong passwords, every password command is refused for
/// `lockoutDuration`, even with the right password. State is exposed so the daemon can persist it
/// and a restart does not reset the counter. Not thread-safe; the command processor serialises access.
public final class LockoutTracker {
    public static let maxAttempts = 5
    public static let lockoutDuration: TimeInterval = 30

    private let now: () -> Date

    public private(set) var failedAttempts: Int
    public private(set) var lockoutUntil: Date?

    public init(now: @escaping () -> Date = Date.init, failedAttempts: Int = 0, lockoutUntil: Date? = nil) {
        self.now = now
        self.failedAttempts = min(max(failedAttempts, 0), Self.maxAttempts - 1)
        self.lockoutUntil = lockoutUntil
        // A stored deadline further away than one lockout period means the clock moved or the
        // file was edited. Never lock out for longer than the documented 30 seconds.
        clampDeadline()
    }

    public var attemptsRemaining: Int { Self.maxAttempts - failedAttempts }

    /// Returns the remaining lockout time, or nil when not locked out.
    public func remainingLockout() -> TimeInterval? {
        clampDeadline()
        guard let until = lockoutUntil else { return nil }
        let current = now()
        if current < until { return until.timeIntervalSince(current) }
        lockoutUntil = nil
        return nil
    }

    /// Records a wrong password. Returns true if this failure started a lockout.
    @discardableResult
    public func recordFailure() -> Bool {
        failedAttempts += 1
        guard failedAttempts >= Self.maxAttempts else { return false }
        failedAttempts = 0
        lockoutUntil = now().addingTimeInterval(Self.lockoutDuration)
        return true
    }

    public func recordSuccess() {
        failedAttempts = 0
        lockoutUntil = nil
    }

    private func clampDeadline() {
        guard let until = lockoutUntil else { return }
        let latest = now().addingTimeInterval(Self.lockoutDuration)
        if until > latest { lockoutUntil = latest }
    }
}
