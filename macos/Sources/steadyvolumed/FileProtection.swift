import Darwin
import Foundation
import SteadyVolumeCore

/// macOS tamper protection, used only by the installed root daemon.
///
/// The installer makes every file root-owned and not writable by others, and launchd's KeepAlive
/// restarts the daemon if it is killed. While protection is on, the daemon also, every 30 seconds:
///   * puts back root:wheel ownership and the expected modes on its plist, binaries and config;
///   * rewrites its LaunchDaemon plist from the copy it read at startup if it was deleted or changed;
///   * re-enables its launchd job if someone ran `launchctl disable` on it.
/// None of this stops root: `sudo launchctl bootout system/com.steadyvolume.daemon` stops the daemon
/// for good, and then nothing runs to repair anything. See the README.
final class FileProtection: TamperProtecting {
    private struct Expected {
        let path: String
        let mode: mode_t
    }

    private static let interval: TimeInterval = 30
    private static let expected: [Expected] = [
        Expected(path: SteadyVolumePaths.launchDaemonPlist, mode: 0o644),
        Expected(path: SteadyVolumePaths.daemonDirectory, mode: 0o755),
        Expected(path: SteadyVolumePaths.daemonBinary, mode: 0o755),
        Expected(path: SteadyVolumePaths.cliBinary, mode: 0o755),
        Expected(path: SteadyVolumePaths.configDirectory, mode: 0o700),
        Expected(path: SteadyVolumePaths.configPath, mode: 0o600),
        Expected(path: SteadyVolumePaths.configPath + ".bak", mode: 0o600),
    ]

    private let log: EventLogging
    private let queue = DispatchQueue(label: "com.steadyvolume.protection")
    private let plistSnapshot: Data?
    private var active = false
    private var timer: DispatchSourceTimer?

    init(log: EventLogging) {
        self.log = log
        // Keep the installed plist so it can be put back. Only trust a root-owned copy.
        var info = stat()
        if lstat(SteadyVolumePaths.launchDaemonPlist, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0 {
            plistSnapshot = FileManager.default.contents(atPath: SteadyVolumePaths.launchDaemonPlist)
        } else {
            plistSnapshot = nil
            log.log(.warning, .protectionError,
                    "The LaunchDaemon plist is missing or not owned by root; it cannot be restored if it is removed.")
        }
    }

    func protect() throws {
        try queue.sync {
            active = true
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(2))
                timer.setEventHandler { [weak self] in self?.repairIfActive() }
                timer.resume()
                self.timer = timer
            }
            let problems = repair()
            if !problems.isEmpty { throw ConfigError(problems.joined(separator: " ")) }
        }
    }

    func restore() throws {
        queue.sync { active = false }
    }

    /// Makes a config file root:wheel with the given mode. Used as the config store's after-write hook.
    static func secureConfigFile(_ path: String) throws {
        let isDirectory = path == SteadyVolumePaths.configDirectory
        guard lchown(path, 0, 0) == 0, chmod(path, isDirectory ? 0o700 : 0o600) == 0 else {
            throw ConfigError("Could not secure \(path): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Repair (on `queue`)

    private func repairIfActive() {
        guard active else { return }
        _ = repair()
    }

    /// Returns problems it could not fix.
    private func repair() -> [String] {
        var problems: [String] = []
        restorePlistIfNeeded(&problems)

        for item in Self.expected {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue } // .bak may not exist yet
            if (info.st_mode & S_IFMT) == S_IFLNK {
                problems.append("\(item.path) has been replaced by a symbolic link.")
                log.log(.error, .protectionError, "\(item.path) has been replaced by a symbolic link; not touching it.")
                continue
            }
            if info.st_uid != 0 || info.st_gid != 0 {
                if lchown(item.path, 0, 0) == 0 {
                    log.log(.warning, .protectionError, "Put back root:wheel ownership of \(item.path).")
                } else {
                    problems.append("Could not reset the owner of \(item.path).")
                }
            }
            if info.st_mode & 0o7777 != item.mode {
                if chmod(item.path, item.mode) == 0 {
                    log.log(.warning, .protectionError,
                            "Put back mode \(String(item.mode, radix: 8)) on \(item.path) (was \(String(info.st_mode & 0o7777, radix: 8))).")
                } else {
                    problems.append("Could not reset the mode of \(item.path).")
                }
            }
        }

        reenableJobIfDisabled(&problems)
        return problems
    }

    private func restorePlistIfNeeded(_ problems: inout [String]) {
        guard let plistSnapshot else { return }
        let path = SteadyVolumePaths.launchDaemonPlist
        var info = stat()
        let exists = lstat(path, &info) == 0
        if exists, (info.st_mode & S_IFMT) == S_IFREG, FileManager.default.contents(atPath: path) == plistSnapshot { return }
        if exists { unlink(path) }
        if FileManager.default.createFile(atPath: path, contents: plistSnapshot,
                                          attributes: [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0]) {
            log.log(.warning, .protectionError, exists ? "The LaunchDaemon plist was changed; put the original back."
                                                       : "The LaunchDaemon plist was deleted; put it back.")
        } else {
            problems.append("Could not restore \(path).")
        }
    }

    private func reenableJobIfDisabled(_ problems: inout [String]) {
        guard let output = Self.run("/bin/launchctl", ["print-disabled", "system"]) else { return }
        // Lines look like:   "com.steadyvolume.daemon" => disabled   (or "=> true" on older systems)
        let label = "\"\(SteadyVolumePaths.launchDaemonLabel)\""
        let disabled = output.split(separator: "\n").contains { line in
            line.contains(label) && (line.contains("=> disabled") || line.contains("=> true"))
        }
        guard disabled else { return }
        if Self.run("/bin/launchctl", ["enable", "system/\(SteadyVolumePaths.launchDaemonLabel)"]) != nil {
            log.log(.warning, .protectionError, "The launchd job had been disabled; enabled it again.")
        } else {
            problems.append("The launchd job is disabled and could not be enabled again.")
        }
    }

    /// Runs a tool and returns its output, or nil if it failed.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
