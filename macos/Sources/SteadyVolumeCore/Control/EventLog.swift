import Foundation

/// Event IDs, the same numbers the Windows version writes to the Event Log.
public enum LogEvent: Int, CustomStringConvertible {
    case serviceStarted = 1000
    case serviceStopping = 1001
    case passwordCreated = 1100
    case locked = 1101
    case unlocked = 1102
    case passwordChanged = 1103
    case unprotected = 1104
    case protected = 1105
    case deviceAdded = 1106
    case failedPassword = 2000
    case lockoutStarted = 2001
    case refusedLockedOut = 2002
    case volumeReverted = 3000
    case devicesChanged = 3001
    case configError = 9000
    case protectionError = 9001
    case audioError = 9002
    case ipcError = 9003
    case startupError = 9999

    public var description: String { "\(rawValue)" }
}

public enum LogLevel {
    case info, notice, warning, error
}

/// Where the Core library logs. The daemon writes to unified logging (os.Logger).
public protocol EventLogging: AnyObject {
    func log(_ level: LogLevel, _ event: LogEvent, _ message: String)
}

/// Discards everything.
public final class NullEventLog: EventLogging {
    public init() {}
    public func log(_ level: LogLevel, _ event: LogEvent, _ message: String) {}
}

/// Platform hook for tamper protection.
public protocol TamperProtecting: AnyObject {
    /// Applies protection. Must be idempotent.
    func protect() throws
    /// Removes protection so the daemon can be uninstalled.
    func restore() throws
}

/// Used in development mode.
public final class NoTamperProtection: TamperProtecting {
    public init() {}
    public func protect() throws {}
    public func restore() throws {}
}
