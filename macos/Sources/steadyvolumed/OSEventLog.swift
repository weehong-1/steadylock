import Foundation
import os
import SteadyVolumeCore

/// Writes events to unified logging under subsystem com.steadyvolume.
/// View with: log show --predicate 'subsystem == "com.steadyvolume"' --info --last 1h
/// Lock, unlock, password and revert events use the default level, which is persisted to disk.
final class OSEventLog: EventLogging {
    static let subsystem = "com.steadyvolume"

    private let logger: Logger
    private let echoToStderr: Bool

    init(category: String = "daemon", echoToStderr: Bool = false) {
        logger = Logger(subsystem: Self.subsystem, category: category)
        self.echoToStderr = echoToStderr
    }

    func log(_ level: LogLevel, _ event: LogEvent, _ message: String) {
        let text = "[\(event.rawValue)] \(message)"
        switch level {
        case .info, .notice: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        if echoToStderr {
            let stamp = Self.timestamp.string(from: Date())
            FileHandle.standardError.write(Data("\(stamp) \(level) \(text)\n".utf8))
        }
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
