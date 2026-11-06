# Install SteadyVolume

## Mac

**1. Download** [steadyvolume-macos-universal.zip](https://nightly.link/weehong-1/volume-lock/workflows/build/main/steadyvolume-macos-universal.zip) and double click it to unzip.

**2. Install.** Open Terminal and paste:

```bash
cd ~/Downloads/steadyvolume-macos-universal
sudo bash ./install.sh
```

Type your Mac password. Then choose a SteadyVolume password when asked.

**3. Lock the volume:**

```bash
steadyvol lock
```

Done. Press a volume key: the volume jumps back.

> **"Apple could not verify steadyvol"** or **`Bootstrap failed: 5`?** Click **Done**, then run this and repeat step 2:
>
> ```bash
> xattr -dr com.apple.quarantine ~/Downloads/steadyvolume-macos-universal
> ```
>
> Still failing? Restart the Mac and repeat step 2. Then [open an issue](https://github.com/weehong-1/volume-lock/issues) with the output.

**Remove it:**

```bash
steadyvol unprotect
sudo bash ~/Downloads/steadyvolume-macos-universal/uninstall.sh
```

## Windows

**1. Download** [steadyvolume-windows-x64.zip](https://nightly.link/weehong-1/volume-lock/workflows/build/main/steadyvolume-windows-x64.zip), right click it, choose **Extract All**.

**2. Install.** Right click **Start**, choose **Terminal (Admin)**, and paste:

```powershell
cd $HOME\Downloads\steadyvolume-windows-x64
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1 -LockCurrentLevels
```

Choose a SteadyVolume password when asked.

Done. The volume is locked. Press a volume key: it jumps back.

**Remove it** (Terminal (Admin) again):

```powershell
steadyvol unprotect
cd $HOME\Downloads\steadyvolume-windows-x64
Set-ExecutionPolicy -Scope Process Bypass -Force
.\uninstall.ps1
```

## Commands

| Command | Does |
|---|---|
| `steadyvol status` | Show what is locked |
| `steadyvol lock` | Lock at the current volume |
| `steadyvol lock 30` | Lock at 30% |
| `steadyvol unlock` | Unlock |
| `steadyvol passwd` | Change the password |

Everything except `status` asks for the SteadyVolume password.
