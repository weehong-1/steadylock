import Darwin
import Foundation
import SteadyVolumeCore

signal(SIGPIPE, SIG_IGN)

let mode: DaemonMode
do {
    mode = try DaemonOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(DaemonOptions.usage)\n".utf8))
    exit(2)
}

switch mode {
case .help:
    print(DaemonOptions.usage)
    exit(0)
case .version:
    print("steadyvolumed \(SteadyVolumePaths.version)")
    exit(0)
case .probe(let options):
    exit(Probe.run(options))
case .daemon(let options):
    Daemon(options: options).run()
}

/// Wires the config, command processor, enforcer and control socket together, then runs forever.
final class Daemon {
    private let options: DaemonOptions
    private let log: OSEventLog
    private var signalSources: [DispatchSourceSignal] = []

    init(options: DaemonOptions) {
        self.options = options
        log = OSEventLog(echoToStderr: options.devMode)
    }

    func run() -> Never {
        if !options.devMode && geteuid() != 0 {
            log.log(.error, .startupError, "steadyvolumed must run as root (it is started by launchd). Use --dev for development.")
            exit(1)
        }

        let store = ConfigStore(path: options.configPath,
                                afterWrite: options.devMode ? nil : FileProtection.secureConfigFile)
        let config = loadConfig(store)

        let enforcer = VolumeEnforcer(backend: CoreAudioBackend(), log: log, dryRun: options.dryRun)
        let protection: TamperProtecting = options.devMode ? NoTamperProtection() : FileProtection(log: log)
        let processor = CommandProcessor(store: store, initialConfig: config, protection: protection, log: log,
                                         snapshots: enforcer)

        let status = processor.status()
        let lockText = !status.locked ? "no"
            : status.mode == .currentLevels ? "yes, at current levels on \(status.devices?.count ?? 0) device(s)"
            : "yes, at \(status.level)% on every device"
        let modeText = options.devMode ? (options.dryRun ? " in development mode (dry run)" : " in development mode") : ""
        log.log(.info, .serviceStarted,
                "SteadyVolume \(SteadyVolumePaths.version) started\(modeText) as uid \(geteuid()). Console user: \(Probe.consoleUser()). "
                + "Locked: \(lockText). Protection: \(status.protected ? "on" : "off"). Password set: \(status.passwordSet ? "yes" : "no").")

        processor.applyStartupState()
        processor.targetChanged = { [weak enforcer] in enforcer?.setTarget($0) }
        enforcer.deviceDiscovered = { [weak processor] in processor?.recordDiscoveredDevice($0) }
        enforcer.setTarget(processor.target)
        enforcer.start()

        let server = SocketServer(path: options.socketPath, mode: 0o666, processor: processor, log: log)
        do {
            try server.start()
        } catch {
            log.log(.error, .startupError, "Could not open the control socket \(options.socketPath): \(error)")
            exit(1)
        }
        if options.devMode {
            FileHandle.standardError.write(Data("Config: \(options.configPath)\nSocket: \(options.socketPath)\n".utf8))
        }

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [log] in
                log.log(.info, .serviceStopping, "SteadyVolume is stopping (signal \(sig)).")
                enforcer.stop()
                server.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        withExtendedLifetime((processor, enforcer, server, protection)) {
            dispatchMain()
        }
    }

    private func loadConfig(_ store: ConfigStore) -> SteadyVolumeConfig {
        do {
            return try store.load()
        } catch {
            log.log(.error, .configError,
                    "The config file and its backup are unreadable (\(error)). They were renamed with a .corrupt suffix and "
                    + "the daemon started unlocked with no password. Run 'steadyvol setup' again.")
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            for path in [store.filePath, store.backupPath] where FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.moveItem(atPath: path, toPath: "\(path).corrupt-\(stamp)")
            }
            return SteadyVolumeConfig()
        }
    }
}
