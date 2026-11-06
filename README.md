# SteadyVolume

Locks the master volume on Windows 11 and macOS. Volume keys, sliders, Settings and scripts can't change it. Unlocking needs a password.

* `steadyvol lock` keeps every speaker and headset at the level it has now.
* `steadyvol lock 30` puts them all at 30%.
* Mute, app volumes and microphones are left alone.

**[Install it](INSTALL.md)**

> An administrator who is determined enough can still get around it. See [Limitations](docs/limitations.md).

## Commands

| Command | Does |
|---|---|
| `steadyvol status` | Show what is locked |
| `steadyvol lock` | Lock at the current volume |
| `steadyvol lock 30` | Lock at 30% |
| `steadyvol unlock` | Unlock |
| `steadyvol passwd` | Change the password |
| `steadyvol unprotect` | Allow uninstalling |

## More

| Doc | For |
|---|---|
| [INSTALL.md](INSTALL.md) | Installing and removing it |
| [docs/macos.md](docs/macos.md) | Mac details: building, troubleshooting, forgotten password |
| [docs/windows.md](docs/windows.md) | Windows details: install options, forgotten password |
| [docs/limitations.md](docs/limitations.md) | What it can't stop |
| [docs/how-it-works.md](docs/how-it-works.md) | Design and code layout |
| [docs/testing.md](docs/testing.md) | What is verified, test checklists |
| [docs/releasing.md](docs/releasing.md) | Publishing a release |
