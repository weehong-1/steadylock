import Darwin
import Foundation
import SteadyVolumeCore

signal(SIGPIPE, SIG_IGN)

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let wrongPassword: Int32 = 3
    static let lockedOut: Int32 = 4
    static let serviceUnavailable: Int32 = 5
}

let usage = """
steadyvol - control the SteadyVolume daemon

Usage:
  steadyvol status          Show lock state, levels, protection and daemon state
  steadyvol lock            Lock every output device at its current level  [password]
                            (nothing is changed; devices plugged in later are
                            held at the level they have when they appear)
  steadyvol lock LEVEL      Lock every output device at LEVEL (0-100)      [password]
  steadyvol unlock          Stop enforcing the volume                       [password]
  steadyvol passwd          Change the password                             [password]
  steadyvol unprotect       Remove tamper protection so you can uninstall   [password]
  steadyvol setup           Create the first password (also offered automatically)
  steadyvol version         Show the CLI version

Passwords are always typed at a hidden prompt, never given as arguments.
"""

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

final class CliApp {
    private var socketPath = SteadyVolumePaths.socketPath
    private var devSocket = false

    private var client: DaemonClient { DaemonClient(socketPath: socketPath, verifyServer: !devSocket) }

    func run(_ rawArgs: [String]) -> Int32 {
        guard let args = extractGlobalOptions(rawArgs) else { return ExitCode.usage }
        do {
            switch args {
            case []:
                print(usage)
                return ExitCode.usage
            case ["help"], ["--help"], ["-h"]:
                print(usage)
                return ExitCode.ok
            case ["version"], ["--version"]:
                print("steadyvol \(SteadyVolumePaths.version)")
                return ExitCode.ok
            case ["status"]:
                return try status()
            case ["setup"]:
                return try setupCommand()
            case ["lock"]:
                return try passwordCommand(.lock, level: nil)
            case _ where args.count == 2 && args[0] == "lock":
                guard let level = Int(args[1]), VolumeMath.isValidLevel(level) else {
                    printError("LEVEL must be a whole number from 0 to 100.")
                    return ExitCode.usage
                }
                return try passwordCommand(.lock, level: level)
            case ["unlock"]:
                return try passwordCommand(.unlock, level: nil)
            case ["passwd"]:
                return try passwordCommand(.changePassword, level: nil)
            case ["unprotect"]:
                return try passwordCommand(.unprotect, level: nil)
            default:
                if args.contains(where: { $0.lowercased().hasPrefix("--pass") || $0.hasPrefix("-p") }) {
                    printError("Passwords are never accepted as arguments; you will be prompted.")
                }
                printError(usage)
                return ExitCode.usage
            }
        } catch let error as DaemonUnavailableError {
            printError(error.description)
            printError(describeDaemonState())
            return ExitCode.serviceUnavailable
        } catch {
            printError("\(error)")
            return ExitCode.failure
        }
    }

    private func extractGlobalOptions(_ rawArgs: [String]) -> [String]? {
        var args: [String] = []
        var rest = rawArgs[...]
        while let arg = rest.popFirst() {
            if arg == "--socket" {
                guard let path = rest.popFirst() else {
                    printError("--socket needs a socket path.")
                    return nil
                }
                socketPath = path
                devSocket = path != SteadyVolumePaths.socketPath
                continue
            }
            args.append(arg)
        }
        if devSocket { printError("[dev] Using socket '\(socketPath)'. The root identity check is skipped.") }
        return args
    }

    // MARK: - Commands

    private func status() throws -> Int32 {
        let (description, running) = daemonState()
        print(description)
        if !running { return ExitCode.serviceUnavailable }

        let response: IpcResponse
        do {
            response = try client.send(IpcRequest(command: .status))
        } catch let error as DaemonUnavailableError {
            printError(error.description)
            return ExitCode.serviceUnavailable
        }
        guard response.ok, let s = response.status else { return report(response) }

        if !s.locked {
            print("  Lock:        unlocked")
        } else if s.mode == .currentLevels {
            let devices = s.devices ?? []
            print("  Lock:        locked at current levels (\(devices.count) device(s); new devices keep their level)")
            for d in devices.sorted(by: { ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending }) {
                print("                 \(String(repeating: " ", count: max(0, 3 - String(d.level).count)))\(d.level)%  \(d.name ?? d.id)")
            }
        } else {
            print("  Lock:        locked at \(s.level)% on every output device")
        }
        print("  Protection:  \(s.protected ? "on" : "off (the daemon can be uninstalled)")")
        print("  Password:    \(s.passwordSet ? "set" : "not set (run 'steadyvol setup')")")
        print("  Version:     \(s.serviceVersion ?? "unknown")")
        return ExitCode.ok
    }

    private func setupCommand() throws -> Int32 {
        if try getStatus().passwordSet {
            printError("A password already exists. Use 'steadyvol passwd' to change it.")
            return ExitCode.failure
        }
        return try createPassword() == nil ? ExitCode.failure : ExitCode.ok
    }

    private func passwordCommand(_ command: IpcCommand, level: Int?) throws -> Int32 {
        let current = try getStatus()

        let password: String
        if !current.passwordSet {
            print("No password has been set yet. Create one now.")
            guard let created = try createPassword() else { return ExitCode.failure }
            if command == .changePassword { return ExitCode.ok }
            password = created
        } else {
            password = PasswordPrompt.read(command == .changePassword ? "Current password: " : "Password: ")
        }

        var newPassword: String?
        if command == .changePassword {
            guard let entered = promptNewPassword() else { return ExitCode.failure }
            newPassword = entered
        }

        return report(try client.send(IpcRequest(command: command, password: password, newPassword: newPassword, level: level)))
    }

    /// Returns the new password on success, nil on failure.
    private func createPassword() throws -> String? {
        guard let password = promptNewPassword() else { return nil }
        let response = try client.send(IpcRequest(command: .setup, newPassword: password))
        return report(response) == ExitCode.ok ? password : nil
    }

    private func promptNewPassword() -> String? {
        for _ in 0..<3 {
            let first = PasswordPrompt.read("New password: ")
            if let problem = PasswordPolicy.check(first) {
                printError(problem)
                continue
            }
            let second = PasswordPrompt.read("Repeat new password: ")
            if first != second {
                printError("The passwords do not match.")
                continue
            }
            return first
        }
        printError("Giving up.")
        return nil
    }

    private func getStatus() throws -> StatusInfo {
        let response = try client.send(IpcRequest(command: .status))
        guard response.ok, let status = response.status else {
            throw DaemonUnavailableError(description: response.message ?? "The daemon did not return its status.")
        }
        return status
    }

    private func report(_ response: IpcResponse) -> Int32 {
        if response.ok {
            if let message = response.message, !message.isEmpty { print(message) }
            if let warning = response.warning, !warning.isEmpty { printError("Warning: " + warning) }
            return ExitCode.ok
        }
        switch response.error {
        case .wrongPassword:
            if let left = response.attemptsRemaining {
                printError("Wrong password. \(left) attempt(s) left before a \(Int(LockoutTracker.lockoutDuration))-second lockout.")
            } else {
                printError("Wrong password.")
            }
            return ExitCode.wrongPassword
        case .lockedOut:
            if let wait = response.retryAfterSeconds {
                printError("\(response.message ?? "Locked out.") Password commands are refused for another \(wait) s.")
            } else {
                printError(response.message ?? "Locked out.")
            }
            return ExitCode.lockedOut
        default:
            printError(response.message ?? "The daemon refused the command (\(response.error.rawValue)).")
            return ExitCode.failure
        }
    }

    private func describeDaemonState() -> String { daemonState().description }

    private func daemonState() -> (description: String, running: Bool) {
        if devSocket { return ("SteadyVolume (development socket)", true) }
        let state: String
        var running = false
        if let pid = client.peerPID() {
            state = "running (PID \(pid))"
            running = true
        } else if FileManager.default.fileExists(atPath: SteadyVolumePaths.launchDaemonPlist) {
            state = "installed, but not answering"
        } else {
            state = "not installed"
        }
        return ("SteadyVolume\n  Daemon:      \(state)", running)
    }
}

exit(CliApp().run(Array(CommandLine.arguments.dropFirst())))
