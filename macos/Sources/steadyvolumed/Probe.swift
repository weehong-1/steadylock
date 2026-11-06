import CoreAudio
import Foundation
import SteadyVolumeCore
import SystemConfiguration

/// `steadyvolumed --probe`: checks that this process (for example root, before or after login) can see,
/// read and observe the master volume of every output device, using the same code as the daemon.
///
/// Read-only by default: nothing is written. `--write-same` writes each device's current value back
/// unchanged (proving the write is allowed without changing the volume). `--watch SECONDS` counts
/// volume-change notifications while you press the volume keys yourself. Mute is only ever read.
enum Probe {
    struct Options {
        var writeSame = false
        var watchSeconds: Int = 0
    }

    static func run(_ options: Options) -> Int32 {
        var failures: [String] = []
        print("SteadyVolume probe \(SteadyVolumePaths.version)")
        print("  Process:        uid \(getuid()) euid \(geteuid())\(geteuid() == 0 ? " (root)" : ""), pid \(getpid())")
        print("  Console user:   \(consoleUser())")

        let backend = CoreAudioBackend()
        let notifications = NotificationCounter()
        do {
            try backend.connect { notifications.record($0) }
            print("  System listeners: added")
        } catch {
            failures.append("system listeners: \(error)")
            print("  System listeners: FAILED (\(error))")
        }

        let scan: DeviceScan
        do {
            scan = try backend.scanOutputDevices()
        } catch {
            print("  Devices: FAILED (\(error))")
            print("RESULT: FAIL")
            return 1
        }

        let defaultID = HAL.defaultOutputDevice()
        print("  Output devices with a settable volume: \(scan.devices.count)")
        var before: [String: (Float32, Bool?)] = [:]
        for case let device as CoreAudioDevice in scan.devices {
            let isDefault = device.objectID == defaultID ? "  [default output]" : ""
            print("    \(device.name.map { "'\($0)'" } ?? "(no name)")\(isDefault)")
            print("      uid:      \(device.id)")
            print("      control:  \(device.control)")
            do {
                let volume = try device.readVolume()
                let mute = HAL.readMute(device.objectID)
                before[device.id] = (volume, mute)
                print("      volume:   \(volume) (\(VolumeMath.toPercent(volume))%)   mute: \(mute.map { $0 ? "on" : "off" } ?? "n/a")")
            } catch {
                failures.append("read \(device.id): \(error)")
                print("      volume:   READ FAILED (\(error))")
            }
        }
        for skipped in scan.skipped { print("  Note: \(skipped.reason)") }

        if options.writeSame {
            print("  Write test (writes each device's current value back unchanged):")
            for case let device as CoreAudioDevice in scan.devices {
                guard let (volume, _) = before[device.id] else { continue }
                do {
                    try device.writeVolume(volume)
                    let after = try device.readVolume()
                    let ok = VolumeMath.toPercent(after) == VolumeMath.toPercent(volume)
                    print("    \(device.name ?? device.id): write OK, read back \(after)\(ok ? "" : "  CHANGED")")
                    if !ok { failures.append("write-same changed \(device.id)") }
                } catch {
                    failures.append("write \(device.id): \(error)")
                    print("    \(device.name ?? device.id): WRITE FAILED (\(error))")
                }
            }
        } else {
            print("  Write test: skipped (read-only). Add --write-same to write each current value back unchanged.")
        }

        if options.watchSeconds > 0 {
            print("  Watching for \(options.watchSeconds) s: press the volume keys or move the slider now.")
            Thread.sleep(forTimeInterval: TimeInterval(options.watchSeconds))
            let counts = notifications.counts
            print("    volume notifications: \(counts.volume), device notifications: \(counts.devices)")
            if counts.volume == 0 {
                print("    No volume notification was received. If you did change the volume, notifications do not")
                print("    reach this process; the daemon would then rely on its 250 ms poll.")
            }
            for case let device as CoreAudioDevice in scan.devices {
                if let volume = try? device.readVolume() {
                    print("    now: \(device.name ?? device.id) \(volume) (\(VolumeMath.toPercent(volume))%)")
                }
            }
        }

        backend.disconnect()
        print("  Listeners removed")

        // Read-only snapshot lines, for comparing before and after a test.
        for case let device as CoreAudioDevice in scan.devices {
            let volume = (try? device.readVolume()).map { "\($0)" } ?? "?"
            let mute = HAL.readMute(device.objectID).map { $0 ? "1" : "0" } ?? "n/a"
            print("SNAPSHOT \(device.id) volume=\(volume) mute=\(mute)")
        }

        if failures.isEmpty {
            print("RESULT: PASS")
            return 0
        }
        print("RESULT: FAIL (\(failures.joined(separator: "; ")))")
        return 1
    }

    static func consoleUser() -> String {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else { return "none" }
        return name == "loginwindow" ? "none (login window)" : "\(name) (uid \(uid))"
    }

    private final class NotificationCounter {
        private let lock = NSLock()
        private var volume = 0
        private var devices = 0

        func record(_ change: AudioChange) {
            lock.lock()
            if change == .volume { volume += 1 } else { devices += 1 }
            lock.unlock()
        }

        var counts: (volume: Int, devices: Int) {
            lock.lock(); defer { lock.unlock() }
            return (volume, devices)
        }
    }
}
