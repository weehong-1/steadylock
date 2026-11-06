import Foundation
import SteadyVolumeCore

/// No arguments: the installed daemon (launchd starts it as root). Everything else is for
/// development and diagnostics.
enum DaemonMode {
    case daemon(DaemonOptions)
    case probe(Probe.Options)
    case help
    case version
}

struct DaemonOptions {
    var devMode = false
    var configPath = SteadyVolumePaths.configPath
    var socketPath = SteadyVolumePaths.socketPath
    var dryRun = false

    static let usage = """
    steadyvolumed: the SteadyVolume daemon.
    It is normally started by launchd as root with no arguments.

    Development and diagnostics:
      --dev [--config PATH] [--socket PATH] [--enforce]
          Run in this terminal as the current user with a separate config file and socket.
          Tamper protection and ownership changes are skipped. Volume changes are only
          logged (dry run) unless --enforce is given.
      --probe [--write-same] [--watch SECONDS]
          Check that this process can see, read and observe every output device's volume.
          Read-only unless --write-same, which writes each current value back unchanged.
          --watch counts volume notifications while you change the volume yourself.
    """

    static func parse(_ args: [String]) throws -> DaemonMode {
        if args.isEmpty { return .daemon(DaemonOptions()) }
        if args == ["--help"] || args == ["-h"] { return .help }
        if args == ["--version"] { return .version }

        if args.first == "--probe" {
            var probe = Probe.Options()
            var rest = args.dropFirst()
            while let arg = rest.popFirst() {
                switch arg {
                case "--write-same": probe.writeSame = true
                case "--watch":
                    guard let text = rest.popFirst(), let seconds = Int(text), (1...600).contains(seconds) else {
                        throw ConfigError("--watch needs a number of seconds from 1 to 600.")
                    }
                    probe.watchSeconds = seconds
                default: throw ConfigError("Unknown probe argument '\(arg)'.")
                }
            }
            return .probe(probe)
        }

        var options = DaemonOptions()
        var dev = false
        var enforce = false
        var config: String?
        var socket: String?
        var rest = args[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--dev": dev = true
            case "--enforce": enforce = true
            case "--config":
                guard let value = rest.popFirst() else { throw ConfigError("--config needs a path.") }
                config = value
            case "--socket":
                guard let value = rest.popFirst() else { throw ConfigError("--socket needs a path.") }
                socket = value
            default: throw ConfigError("Unknown or incomplete argument '\(arg)'.")
            }
        }
        guard dev else { throw ConfigError("--config, --socket and --enforce are only valid together with --dev.") }

        let socketPath = socket ?? SteadyVolumePaths.devSocketPath
        let configPath = URL(fileURLWithPath: config ?? SteadyVolumePaths.devConfigPath).standardizedFileURL.path
        guard socketPath != SteadyVolumePaths.socketPath else {
            throw ConfigError("Development mode must not use the production socket.")
        }
        guard configPath != SteadyVolumePaths.configPath else {
            throw ConfigError("Development mode must not use the production config.")
        }
        options.devMode = true
        options.configPath = configPath
        options.socketPath = socketPath
        options.dryRun = !enforce
        return .daemon(options)
    }
}
