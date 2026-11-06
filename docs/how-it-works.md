# How it works

```
 volume keys / slider / Settings / mixer / scripts
                     │  change
                     ▼
        Windows Core Audio endpoint volume ──notification──┐
                     ▲                                       │ (callback only signals)
                     │ SetMasterVolumeLevelScalar            ▼
            ┌────────┴─────────────────────────────────────────────┐
            │ SteadyVolume service (LocalSystem, session 0)          │
            │  enforcer thread: wakes on signal or every 250 ms,     │
            │  compares rounded whole percents, reverts if different │
            │  pipe server ◄── steadyvol.exe (status/lock/unlock/…)  │
            └────────────────────────────────────────────────────────┘
```

* **Revert:** each active render endpoint has an `IAudioEndpointVolume` change callback, and `IMMNotificationClient` reports device add, remove, state and default-device changes. Callbacks only set a flag and signal an event. A dedicated MTA thread owns every Core Audio object and does all reads and writes. It also wakes every 250 ms in case a notification is missed.
* **Lock at current levels:** `steadyvol lock` asks the service to read every active output device's exact level (for example 0.4998). The read happens on the enforcement thread, like every other audio call. The levels are saved per device in the config. A revert writes back that exact stored value, not a rounded percent. A device with no stored level is held at the level it reports when first seen, and that level is saved too (event 1106).
* **No feedback loops:** levels are compared as rounded whole percents before anything is written. The service's own write triggers a notification, finds the level already correct, and stops. If a device's hardware volume steps can't reach the exact percent, the closest value the device accepts is used, so the service never rewrites endlessly.
* **Service:** an automatic-start LocalSystem service that depends on `Audiosrv`, so it starts at boot before anyone logs in. Recovery is "restart immediately" on every failure, indefinitely: all three actions are restart with a 0 ms delay, and `failureflag` is on.
* **Control channel:** the named pipe `\\.\pipe\SteadyVolume`. Any authenticated local user can connect, network logons are denied, and only SYSTEM can create pipe instances. The CLI checks that the pipe server's process ID is the SteadyVolume service's process ID before sending a password, so a program that grabbed the pipe name first can't collect it.
* **Config:** `C:\ProgramData\SteadyVolume\config.json`, written only by the service. Saves are atomic (temp file then replace) and the previous version is kept as `config.json.bak`. The folder and files are owned by SYSTEM, with SYSTEM full control, Administrators read only and no access for anyone else. Inheritance is cut.
* **Passwords:** PBKDF2-HMAC-SHA256 with a 16-byte random salt and 600,000 iterations for new hashes. Stored hashes with fewer than 210,000 iterations are refused, so a downgraded config can't weaken them. Comparison is constant-time. After 5 wrong passwords in a row, every password command is refused for 30 seconds, even with the right password. The counter is saved, so restarting the service doesn't reset it. Passwords are only ever read at a hidden prompt (or from redirected stdin), never from arguments.
* **Tamper protection:** while protection is on, the service's DACL gives SYSTEM full control, Administrators query and start only, and users query only. Administrators therefore can't stop, pause, reconfigure or delete it. `steadyvol unprotect` (with the password) makes the service restore the original DACL. `steadyvol lock` turns protection back on.
* **Logging:** Windows Application Event Log, source `SteadyVolume`.

| Event ID | Meaning |
|---|---|
| 1000 / 1001 | Service started / stopping |
| 1100–1106 | Password created, locked, unlocked, password changed, unprotected, protection on, new device locked at its current level |
| 2000 / 2001 / 2002 | Wrong password / lockout started / command refused during lockout |
| 3000 | Volume reverted. The first revert per device is logged immediately; further reverts within 10 s are summarised in one entry. |
| 3001 | Set of watched output devices changed |
| 9000–9003, 9999 | Config, protection, audio, pipe and startup errors |

## On macOS

The macOS version is a port of the same design. The command processor, config rules, password rules, lockout, IPC messages, log event numbers and CLI text and exit codes match Windows.

* **Revert:** CoreAudio property listeners watch every output device's virtual main volume (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, the value the menu bar slider, Control Center and the volume keys change) and its volume scalars. System listeners report device list changes, default output device changes and a `coreaudiod` restart. Listener blocks only set a flag and signal. One worker thread does every CoreAudio read and write and also wakes every 250 ms. The HAL is told to deliver notifications on its own thread, because a daemon has no main run loop.
* **Which control is written:** the virtual main volume (it keeps the left/right balance). If a device doesn't have it, the main-element volume scalar. Failing that, each stereo channel's scalar. Devices with no settable volume, such as most HDMI and DisplayPort outputs, are skipped and logged once.
* **Daemon:** `/Library/LaunchDaemons/com.steadyvolume.daemon.plist`, running `/usr/local/libexec/steadyvolume/steadyvolumed` as root with `RunAtLoad`, `KeepAlive` and `ThrottleInterval` 1, so it starts at boot before login and is restarted if killed.
* **Control channel:** the Unix socket `/var/run/steadyvolume.sock`, mode 0666, so any local user can connect. Only root can create files in `/var/run`. Before sending a password, the CLI checks with `getpeereid` that the process at the other end runs as root.
* **Config:** `/Library/Application Support/SteadyVolume/config.json`, root:wheel, mode 600, in a root-only (700) folder. Saves are atomic (temp file, `F_FULLFSYNC`, rename) and keep `config.json.bak`.
* **Tamper protection:** every installed file is root-owned and not writable by others. While protection is on, the daemon checks every 30 s and puts back the owners and modes of its plist, binaries and config. It rewrites the plist from the copy it read at startup if the plist was deleted or edited, and runs `launchctl enable` again if its job was disabled. `steadyvol unprotect` turns this off, and `uninstall.sh` refuses to run until you have done so. **Root can still stop it**; see [Limitations](limitations.md).
* **Logging:** unified logging, subsystem `com.steadyvolume`. Messages start with the Windows event ID, for example `[1101]`. Lock, unlock, password and revert events are logged at the default level, which is kept on disk.

## Repository layout

```
windows/                      .NET 10 solution
  src/SteadyVolume.Core/      config store, password hashing, lockout, IPC contracts, command processor
  src/SteadyVolume.Service/   Windows service: enforcer (NAudio), pipe server, tamper protection, --probe
  src/SteadyVolume.Cli/       steadyvol.exe
  tests/SteadyVolume.Core.Tests/
  tools/Set-MasterVolume.ps1  manual-test helper (sets volume through Core Audio)
  tools/CoreAudioTest.cs      Core Audio helper for the tests (read/set volume and mute, read-only snapshot)
  sandbox/                    end-to-end tests: SandboxTest.ps1, Invoke-HostTest.ps1, Start-SandboxTest.ps1
  publish.ps1
macos/                        Swift package
  Sources/SteadyVolumeCore/   config store, passwords, lockout, IPC + Unix socket, command processor,
                              enforcement engine (no CoreAudio; tested against a fake audio system)
  Sources/steadyvolumed/      root LaunchDaemon: CoreAudio backend, socket server, tamper protection, --probe
  Sources/steadyvol/          the CLI
  Resources/                  com.steadyvolume.daemon.plist
  Tests/SteadyVolumeCoreTests/
install/windows/              install.ps1, uninstall.ps1, probe-session0.ps1 (all require elevation)
install/macos/                install.sh, uninstall.sh (require sudo)
.github/workflows/build.yml   Windows single-file x64 and macOS universal builds on every push; draft release on v* tags
```

The IPC wire format is shared by both platforms: a 4-byte little-endian length, then UTF-8 JSON with camelCase names and camelCase enum strings, one request and one response per connection.
