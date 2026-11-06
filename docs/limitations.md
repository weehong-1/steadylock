# Limitations

SteadyVolume makes changing the volume **inconvenient**. It does **not** make it impossible for someone with administrator rights. Any administrator who is determined enough can defeat it, for example:

* **Windows:**
  * Take ownership of the service object, or edit `HKLM\SYSTEM\CurrentControlSet\Services\SteadyVolume` (set `Start=4` or change `ImagePath`) and reboot.
  * Take ownership of the program or config folders.
  * Boot into Safe Mode.
  * Kill the process. Windows restarts it by itself, but measured on a real PC there is a gap of about **2.3 seconds** from the kill until the new process is enforcing again. About 0.4 s of that is the service starting; the rest is Windows' service manager noticing the crash and applying the restart action. A change made in that gap is reverted as soon as the service is back. A script that kills it in a loop keeps it down most of the time.
* **macOS:**
  * `sudo launchctl bootout system/com.steadyvolume.daemon` stops the daemon until the next boot. Combined with `sudo launchctl disable system/com.steadyvolume.daemon`, it stays off for good, because nothing is left running to turn it back on.
  * Deleting the plist, binaries or config as root after a `bootout`. (While the daemon is running and protected, it puts the plist, owners and modes back within 30 s, but it can't stop root.)
  * System Settings → General → Login Items & Extensions → Allow in the Background may let an administrator switch the daemon off. **Not verified.**
  * Killing the process: launchd restarts it (`KeepAlive`). The gap hasn't been measured yet.

Other limits:

* **Changes are visible briefly.** A change shows up and is then put back, usually within milliseconds through the notification and at worst within 250 ms through polling. The Windows 11 taskbar Quick Settings slider **cannot be removed**; instant revert is the real defence there.
* `HideSCAVolume` has no effect on Windows 11 24H2 and later.
* macOS has no supported way to disable the volume keys or remove the Control Center slider. On macOS, instant revert is the only defence.
* On macOS, output devices with no software volume control (most HDMI and DisplayPort outputs, some USB DACs) can't be locked. They are skipped and logged; their volume is set on the receiving device.
* The Scancode Map only affects keys that arrive as keyboard scancodes. Some laptop Fn keys and vendor hotkey utilities bypass it. Those changes still hit the endpoint volume and are reverted.
* Per-app volumes (the Volume Mixer's app sliders), mute and microphones are intentionally not locked.
* Physical volume knobs on speakers, amplifiers and headsets are outside Windows' control. Exclusive-mode or ASIO audio that bypasses the Windows mixer may also bypass the master volume.
* If the config and its backup are both corrupt, the service renames them, starts unlocked with no password and logs an error (event 9000).
