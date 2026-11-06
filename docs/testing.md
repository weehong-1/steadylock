# Testing

## Status

| Platform | Status |
|---|---|
| Windows 11 (.NET 10, C#) | Implemented. 104 unit tests pass; the end-to-end install, attack and uninstall test passes on a real PC (80 checks; rerun pending for the lock-at-current-levels change). Enforcement on real speakers is verified only in part. See [What has and has not been verified](#what-has-and-has-not-been-verified). |
| macOS (Swift) | Implemented. 107 unit tests pass (including the enforcement engine against a fake audio system); a read-only probe (also as root, receiving volume notifications) and a dry-run end-to-end test pass on a real Mac, and real reverts on the speakers were confirmed with the development daemon running as the logged-in user. **Not yet verified as the installed root daemon.** See [What has and has not been verified](#what-has-and-has-not-been-verified). |

## What has and has not been verified

### Windows

Verified on Windows 11 26H2 (build 26300), a physical PC with 7 active output devices, Windows PowerShell 5.1.

| Item | Status |
|---|---|
| Solution builds with 0 warnings (warnings are errors) | Verified |
| 104 unit tests: hashing, policy, lockout, config store, command processing, lock at current levels, per-device targets, IPC wire format, throttling, rounding | Verified (pass) |
| `steadyvol lock` (current levels) on real hardware: all 7 devices captured exactly (for example 0.4998 and 0.6800), about 8 enforcement passes find nothing to revert, read-only check confirms no device changed | Verified in development mode as the logged-on user (dry run, scratch config). Not yet as the installed SYSTEM service; the host test now covers it. |
| Audio control as LocalSystem in session 0: enumerate devices, set the volume, receive the change notification, restore, mute untouched | Verified (`probe-session0.ps1`, PASS) |
| Install with `-HideSoundSettings -BlockSndVol -HideScaVolume`: service auto-start, LocalSystem, session 0, depends on Audiosrv, restart-on-every-failure recovery and failure flag | Verified (host test) |
| First-run setup, second setup refused, password not accepted as an argument | Verified (host test) |
| Config folder owned by SYSTEM, inheritance cut, Administrators read-only, no user access; program folder not writable by Administrators; config holds a 600,000-iteration hash, not the password | Verified (host test) |
| As administrator: `sc stop`, `sc pause`, `sc config`, `sc failure`, `sc sdset`, `sc delete` and `Stop-Service` all denied; query still allowed | Verified (host test) |
| `taskkill /f` four times in a row: restarted every time (about 2.3 s), state kept | Verified (host test) |
| 5 wrong passwords lock out every password command for 30 s; the lockout survives a service restart; `status` still works | Verified (host test) |
| Password change, unlock, Event Log entries and their text, `unprotect` restoring the DACL | Verified (host test) |
| Uninstall: service, folders, backup key, event source removed; `SettingsPageVisibility` merged with an existing `hide:home` and restored to it; SndVol key, HideSCAVolume and PATH restored exactly | Verified (host test; also from a half-installed state) |
| Revert speed, mute left alone and log throttling **with the lock on, on real speakers** | **Not verified on real hardware.** The host test was run in no-volume-change mode at the owner's request. Run `Invoke-HostTest.ps1 -AllowVolumeChange` or the Windows Sandbox test to cover it. |
| `-DisableVolumeKeys` (Scancode Map) on real hardware | Bytes and merge logic verified in a dry run only; not applied (needs a reboot). |
| Taskbar slider, Settings app, volume keys, headphone hot-plug, start before login after a reboot | **Not verified.** Use the manual checklist below. |
| Windows Sandbox test (`Start-SandboxTest.ps1`) | **Not run.** Windows Sandbox fails to start on this build (`0x80370106`: its virtual machine restarts itself about a second after starting), even after resetting the feature and turning off vGPU. |

### macOS

Checked on a MacBook Air (Apple Silicon), macOS 27.0.1, Swift 6.4.2, with one output device (MacBook Air Speakers). The speaker volume was never changed: every step was guarded by a read-only check of volume and mute against a baseline taken first.

| Item | Status |
|---|---|
| Debug build with no warnings; universal release build with arm64 and x86_64 slices, minimum macOS 13.0 | Verified. The x86_64 slice hasn't been run (this Mac has no Rosetta). |
| 107 unit tests: hashing (including a PBKDF2 known-answer test), policy, piped-password clean-up, lockout, config store, command processing, lock at current levels, targets, IPC wire format (including JSON in the Windows format), sockets, throttling, rounding, and the enforcer against a fake audio system (revert to the exact value, no write when the rounded percent matches, new-device adoption, coarse hardware steps, dry run, mute never touched, notification and 250 ms poll on the real worker thread, reconnect after an audio failure) | Verified (pass, three runs in a row) |
| `steadyvolumed --probe` as the logged-in user: finds the speakers, picks the virtual main volume (settable), reads 0.5625, adds and removes listeners | Verified (read-only) |
| Development-mode daemon (as the user, dry run) driven by the CLI: setup with a password piped with a byte-order mark and CRLF; second setup refused; password as an argument refused; `lock 101` refused; `lock` at current levels saves exactly 0.5625 and changes nothing; status; config file mode 600 with a 600,000-iteration hash; 5 wrong passwords lock out for 30 s even with the right password; the lockout survives `kill -9` and a restart; passwd; old password refused; `lock 30` only logs "Would revert"; unlock; unprotect; socket removed on exit; production CLI reports "not installed" | Verified |
| Unified log entries persisted and readable with `log show` | Verified |
| Install and uninstall scripts | Syntax-checked, and checked to refuse without sudo. **Not run.** |
| Audio access as root after login: `sudo steadyvolumed --probe --watch 15` finds the speakers, reads the virtual main volume, and receives 56 volume-change notifications while the owner pressed the volume keys | Verified (PASS). Nothing written by the probe. Note that on macOS the volume keys also unmute; SteadyVolume leaves mute alone. |
| Writing the volume as root (`--write-same`), and the launchd daemon before and after login | **Not verified.** Needs `--write-same` and an install. |
| Real revert on the speakers, by the owner, with the development daemon (`--dev --enforce`, as the logged-in user) locked at current levels: the volume keys and the sliders were each reverted to 56% (log: "from 50% to 56%", "from 63% to 56%", bursts of 24–47 reverts summarised every 10 s); afterwards `osascript` reported 56. Mute stayed free, as designed | Verified as the logged-in user. The change shows briefly before it snaps back, as documented. **Not yet verified as the installed root daemon.** |
| `KeepAlive` restart after a kill, file and plist repair, `launchctl enable` again, reboot, headphones hot-plug | **Not verified.** Use the checklist below. |

### End-to-end tests

Both tests install the real service, attack it as an administrator, then unprotect and uninstall it, and check every change was reverted. Reports go to `windows\artifacts\`.

```powershell
# On this PC (elevated). Default: never writes any volume or mute and never locks. A read-only guard
# checks every output device's volume and mute at each stage and uninstalls if anything differs.
.\windows\sandbox\Invoke-HostTest.ps1
# Full version: locks at 20%, changes the default device up to 40%, restores only the default device.
.\windows\sandbox\Invoke-HostTest.ps1 -AllowVolumeChange

# In Windows Sandbox (not elevated): everything, including the volume-key remap, inside a throwaway VM.
.\windows\sandbox\Start-SandboxTest.ps1
```

The host test refuses to run if any part of SteadyVolume is already installed, saves the registry state to `before.json`, and uninstalls automatically if it stops part-way.

## Manual test checklist (Windows)

Install with `-AllExtras`, run `steadyvol lock`, check with `steadyvol status` that every device shows its current level, then reboot once so the Scancode Map applies. "Its level" below means the level `status` lists for that device. Watch Event Viewer → Windows Logs → Application, source SteadyVolume.

- [ ] **Lock changes nothing:** right after `steadyvol lock`, no device's volume has moved and the log has no event 3000.
- [ ] **Volume keys:** Volume Up and Volume Down do nothing (and before reboot, any change is reverted). **Mute key** still mutes and unmutes.
- [ ] **Taskbar Quick Settings slider:** dragging snaps back to the default device's level. Mute toggle works.
- [ ] **Settings app:** System → Sound is hidden. `start ms-settings:sound` shows nothing useful. If reachable, the slider snaps back.
- [ ] **Volume Mixer:** `sndvol.exe` from Win+R does not open. The Settings Volume Mixer page is hidden. Per-app sliders still work, by design.
- [ ] **Script:** `windows\tools\Set-MasterVolume.ps1 -Level 90` reports "The change was reverted."
- [ ] **Headphones / USB / Bluetooth device:** plug in a device that wasn't connected when you locked. It keeps the level it came up with (event 3001, then 1106), and changing it afterwards snaps back to that level. Switching the default device doesn't change any level.
- [ ] **Kill the process:** in an elevated prompt, run `taskkill /f /im steadyvolume-service.exe`. The service restarts by itself within a few seconds and the lock still applies.
- [ ] **Stop as administrator:** `sc stop SteadyVolume` and `Stop-Service SteadyVolume` give access denied. `sc config SteadyVolume start= disabled` and `sc delete SteadyVolume` are also denied.
- [ ] **Wrong password:** five wrong passwords lock out all password commands for 30 s (events 2000, 2001). `status` still works.
- [ ] **Reboot:** after a reboot the service runs before anyone logs in, and at the login screen every device is at its locked level.
- [ ] **Unprotect and uninstall:** `steadyvol unprotect`, then `uninstall.ps1` removes everything. After a reboot the volume keys work again.

## Manual test checklist (macOS)

Before installing, run `sudo …/steadyvolumed --probe --watch 15` and press the volume keys during those 15 seconds. It should report volume notifications greater than 0. Install, run `steadyvol lock`, and check with `steadyvol status` that every device shows its current level. Watch the log in another terminal: `/usr/bin/log stream --predicate 'subsystem == "com.steadyvolume"'`.

- [ ] **Lock changes nothing:** right after `steadyvol lock`, no device's volume has moved and the log has no `[3000]` entry.
- [ ] **Volume keys:** Volume Up and Down snap back (log `[3000]`). The **mute key** still mutes and unmutes.
- [ ] **Control Center and the menu bar Sound slider:** dragging snaps back. Mute isn't affected.
- [ ] **System Settings → Sound → Output volume:** snaps back.
- [ ] **Script:** `osascript -e "set volume output volume 90"` is reverted. `osascript -e "output volume of (get volume settings)"` then shows the locked level.
- [ ] **Headphones, USB or Bluetooth device:** plug in a device that wasn't connected when you locked. It keeps the level it came up with (`[3001]`, then `[1106]`), and later changes snap back to that level. Switching the default output doesn't change any level.
- [ ] **Kill the process:** `sudo kill -9 $(pgrep steadyvolumed)`. launchd restarts it within about a second and the lock still applies. Note how long it took.
- [ ] **Stop as administrator:** `sudo launchctl kill SIGTERM system/com.steadyvolume.daemon` is restarted. `sudo launchctl disable system/com.steadyvolume.daemon` is undone within 30 s (`[9001] … enabled it again`). `sudo chmod 666 /Library/LaunchDaemons/com.steadyvolume.daemon.plist` is undone within 30 s.
- [ ] **Wrong password:** five wrong passwords lock out all password commands for 30 s (`[2000]`, `[2001]`). `status` still works.
- [ ] **Before login:** log out (or reboot) and wait at the login window, then log in and check the log. The daemon's start line says `Console user: none (login window)` and is followed by `Watching N output device(s)`. A volume change made at the login window (volume keys) is reverted.
- [ ] **Reboot:** after a reboot, the daemon runs before anyone logs in and every device is at its locked level.
- [ ] **Unprotect and uninstall:** `uninstall.sh` refuses while protection is on. After `steadyvol unprotect` it removes everything (`ls /usr/local/libexec/steadyvolume /Library/LaunchDaemons/com.steadyvolume.daemon.plist` finds nothing).
