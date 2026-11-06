# macOS

## Build

You need Xcode (or the Swift toolchain) on macOS 13 or later.

```bash
cd macos
swift test                                              # unit tests; never touch real audio
swift build -c release --arch arm64 --arch x86_64       # universal binaries -> .build/out/Products/Release
```

Xcode on macOS 27 warns that the x86_64 architecture is deprecated. The universal build still contains both slices; CI checks them. CI (`.github/workflows/build.yml`) uploads both binaries, the plist and the install scripts as one artifact.

## Install

```bash
sudo ./install/macos/install.sh            # from a downloaded zip: sudo bash ./install.sh  (see ../INSTALL.md)
```

What it does:

1. Runs `steadyvolumed --probe` as root. This is read-only. If root can't see and read the output devices, it stops without installing anything.
2. Copies `steadyvolumed` to `/usr/local/libexec/steadyvolume/` and `steadyvol` to `/usr/local/bin/`, both root:wheel 755, and clears the download quarantine flag.
3. Installs the plist to `/Library/LaunchDaemons` (root:wheel 644) and creates the root-only config folder.
4. Enables the job and loads it with `launchctl bootstrap system`, then waits for the socket. If launchd refuses, it clears any stale registration and tries up to three times. If it still fails, it prints what it found, removes everything it installed, and stops (see [If the install fails to load the daemon](#if-the-install-fails-to-load-the-daemon)).
5. Runs `steadyvol setup` so you choose the password straight away. **Until a password exists, anyone on the Mac could set it.**

If an earlier install stopped part way (its plist is there but the daemon is not loaded and protection is off), running `install.sh` again replaces it. A `config.json` from before is kept.

Then lock:

```bash
steadyvol lock          # every output device at its current level; nothing changes
steadyvol lock 30       # or: every output device at 30%
```

macOS 13 and later may show a "Background Items Added" notification for the daemon.

## If the install fails to load the daemon

`Bootstrap failed: 5: Input/output error` is launchd's general error. `install.sh` already retries and then prints the plist and binary permissions, quarantine flags, the code signature, whether launchd has the job disabled, and recent launchd log lines. The usual causes:

* **Gatekeeper.** A downloaded zip carries a quarantine flag, and the binaries are not notarized, so macOS refuses them ("Apple could not verify ..."). `install.sh` removes the flag by name and checks it is gone, then signs the binaries locally (ad hoc). If it can't, run `xattr -dr com.apple.quarantine ~/Downloads/steadyvolume-macos-universal` and install again.

* **Blocked in Login Items.** On macOS 13 and later, open System Settings > General > Login Items & Extensions and switch on `steadyvolumed` under Allow in the Background, then run `install.sh` again. `sudo sfltool dumpbtm | grep -i -A5 steadyvolume` shows what macOS recorded.
* **A registration launchd is stuck on**, for example after an earlier attempt. Restart the Mac and run `install.sh` again.
* **Disabled with `launchctl disable`.** `install.sh` runs `launchctl enable` before each attempt, so this one clears itself.

## Use

The commands, prompts and exit codes are the same as on Windows (see [Use](windows.md#use)). To read the log:

```bash
/usr/bin/log show --predicate 'subsystem == "com.steadyvolume"' --last 1h
```

Use `/usr/bin/log` rather than `log`, because zsh has its own `log` builtin.

## Uninstall

```bash
steadyvol unprotect                         # password required
sudo ./install/macos/uninstall.sh           # add --keep-config to keep the password and settings
```

## If you forget the password

```bash
sudo launchctl bootout system/com.steadyvolume.daemon
sudo rm "/Library/Application Support/SteadyVolume/config.json" "/Library/Application Support/SteadyVolume/config.json.bak"
sudo launchctl bootstrap system /Library/LaunchDaemons/com.steadyvolume.daemon.plist
steadyvol setup
```

This is the same route a determined administrator can use to defeat the lock.

## Checking audio access as root

```bash
sudo macos/.build/out/Products/Release/steadyvolumed --probe              # read-only
sudo macos/.build/out/Products/Release/steadyvolumed --probe --watch 15   # counts notifications while YOU change the volume
sudo macos/.build/out/Products/Release/steadyvolumed --probe --write-same # writes each current value back unchanged
```

The probe lists each output device, the control it would use, its volume and mute (mute is only ever read), and whether listeners can be added. It ends with `SNAPSHOT` lines you can compare before and after a test. Running it with `sudo` tests root inside your login session. To check the real launchd context before anyone logs in, use the [manual checklist](testing.md#manual-test-checklist-macos): the daemon logs `Console user: none (login window)` at startup, followed by the devices it watches.

If root can't control the audio reliably, the fallback design is a small helper in the logged-in user's session (a LaunchAgent) that the daemon keeps alive. It isn't built, because nothing so far shows it is needed.

## Development mode (no install, nothing changed)

```bash
# terminal 1: runs as you, separate config and socket, logs what it would revert without writing
macos/.build/debug/steadyvolumed --dev
# terminal 2
macos/.build/debug/steadyvol --socket /tmp/steadyvolume-dev-$(id -u).sock status
```

Add `--enforce` to the daemon to really revert the volume. `--config PATH` and `--socket PATH` choose other files.
