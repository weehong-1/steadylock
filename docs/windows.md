# Windows

## Build

> **Why .NET 10 and not .NET 8:** .NET 8 support ends on 10 November 2026. A self-contained build bundles the runtime, so an unsupported runtime would never get security fixes. .NET 10 is the current LTS release, supported until November 2028.

You need the .NET 10 SDK.

```powershell
cd windows
dotnet test                 # unit tests
.\publish.ps1               # self-contained single-file x64 exes -> windows\artifacts\win-x64
```

Trimming is deliberately off because it can break NAudio's COM interop. CI (`.github/workflows/build.yml`) produces the same artifacts with the install scripts included.

## Install

From an **elevated** PowerShell (the scripts refuse to run otherwise):

```powershell
.\install\windows\install.ps1 -LockCurrentLevels
```

What it does:

1. Copies `steadyvolume-service.exe` and `steadyvol.exe` to `C:\Program Files\SteadyVolume`. The folder is owned by SYSTEM; Administrators and Users get read and execute only.
2. Registers the Event Log source.
3. Creates the service: automatic start, LocalSystem, depends on Audiosrv, restart-on-every-failure recovery.
4. Adds the folder to the system PATH.
5. Starts the service and runs `steadyvol setup` so you choose the password straight away. **Until a password exists, anyone on the PC could set it.**
6. With `-LockCurrentLevels`, locks every output device at its current level (nothing changes). With `-Level N`, locks every device at N instead.

Optional switches. Every change is recorded under `HKLM\SOFTWARE\SteadyVolume\InstallBackup` and reverted by the uninstaller:

| Switch | Effect |
|---|---|
| `-DisableVolumeKeys` | `Scancode Map` remaps Volume Down (E0 2E) and Volume Up (E0 30) to nothing. **Mute (E0 20) keeps working.** Existing mappings are kept. **Needs a reboot.** |
| `-HideSoundSettings` | Adds `sound`, `sound-devices`, `sound-defaultoutputproperties`, `sound-defaultinputproperties` and `apps-volume` to the `SettingsPageVisibility` policy, merged with any existing value. |
| `-BlockSndVol` | An Image File Execution Options `Debugger` entry for `SndVol.exe` points at `systray.exe`, a stub that exits immediately. |
| `-HideScaVolume` | Sets the `HideSCAVolume` policy. **Windows 11 24H2 and later ignore it.** It is best effort only. |
| `-AllExtras` | All of the above. |
| `-SkipSetup` | Don't run password setup (for automated tests). Run `steadyvol setup` straight away afterwards. |

## Use

```text
steadyvol status          lock state, per-device levels, protection, service state (no password)
steadyvol lock            lock every device at its current level, changing nothing (password)
steadyvol lock 30         lock every device at 30%   (password)
steadyvol unlock          stop enforcing             (password)
steadyvol passwd          change the password        (password)
steadyvol unprotect       allow stop / uninstall     (password)
steadyvol setup           create the first password
```

If no password exists yet, any password command offers to create one first.

Exit codes: 0 OK, 1 failed, 2 usage, 3 wrong password, 4 locked out, 5 service unavailable or failed the identity check.

## Uninstall

```powershell
steadyvol unprotect                       # password required; otherwise Windows refuses to stop the service
.\install\windows\uninstall.ps1           # elevated; add -KeepConfig to keep the password and settings
```

The uninstaller stops and deletes the service, reverts every optional extra to its original value, removes its PATH entry and the Event Log source, and takes back ownership of the SYSTEM-owned folders before deleting them. If you used `-DisableVolumeKeys`, reboot afterwards.

## If you forget the password

As an administrator:

1. Take ownership of `C:\ProgramData\SteadyVolume`.
2. Delete `config.json` and `config.json.bak`.
3. Reboot.

The service then starts unlocked, with no password. Run `steadyvol setup`, and `steadyvol unprotect` will then work again. This is the same route a determined administrator can use to defeat the lock; see [Limitations](limitations.md).

## Checking session 0 before installing

```powershell
# elevated; runs the probe once as SYSTEM through a temporary scheduled task, then deletes the task
.\install\windows\probe-session0.ps1
```

The probe enumerates output devices, registers device notifications, moves the default device by 1%, waits for the change notification, and restores the original level. It never changes mute. If it fails, **don't install**. The fallback design is a small helper process in the user's session that the service keeps alive.

## Development mode (no install, nothing changed)

```powershell
# terminal 1: separate config and pipe; logs what it would revert without writing
windows\src\SteadyVolume.Service\bin\Debug\net10.0-windows\steadyvolume-service.exe --dev --config $env:TEMP\sv-dev\config.json
# terminal 2
windows\src\SteadyVolume.Cli\bin\Debug\net10.0-windows\steadyvol.exe --pipe SteadyVolume-dev status
```

Add `--enforce` to the service to really revert the volume in your user session.
