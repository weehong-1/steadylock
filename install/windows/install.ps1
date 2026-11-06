#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the SteadyVolume Windows service and the steadyvol command line tool.

.DESCRIPTION
    Copies the binaries to "C:\Program Files\SteadyVolume", registers an automatic LocalSystem
    service that starts at boot (restart on every failure), registers the Event Log source,
    starts the service and runs first-time password setup. Optional switches add extra
    Windows hardening; every change they make is recorded and reverted by uninstall.ps1.

.PARAMETER SourceDir
    Folder containing steadyvolume-service.exe and steadyvol.exe. Defaults to this script's
    folder, then windows\artifacts\win-x64 in the repository.

.PARAMETER Level
    Lock every output device at this level (0-100) straight after setup.

.PARAMETER LockCurrentLevels
    Lock every output device at its current level straight after setup. Nothing is changed.

.PARAMETER DisableVolumeKeys
    Disable the Volume Up and Volume Down keys with a Scancode Map (Mute keeps working). Needs a reboot.

.PARAMETER HideSoundSettings
    Hide the Sound pages in the Settings app (SettingsPageVisibility policy).

.PARAMETER BlockSndVol
    Stop SndVol.exe (classic Volume Mixer) from starting (Image File Execution Options).

.PARAMETER HideScaVolume
    Set the HideSCAVolume policy. Best effort only: Windows 11 24H2 and later ignore it.

.PARAMETER AllExtras
    All four extras above.

.PARAMETER SkipSetup
    Do not run first-run password setup (for automated tests). Run "steadyvol setup" yourself
    straight away: until a password exists, anyone on the PC could set it.

.EXAMPLE
    .\install.ps1 -Level 30 -AllExtras
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [ValidateRange(-1, 100)][int]$Level = -1,
    [switch]$LockCurrentLevels,
    [switch]$DisableVolumeKeys,
    [switch]$HideSoundSettings,
    [switch]$BlockSndVol,
    [switch]$HideScaVolume,
    [switch]$AllExtras,
    [switch]$SkipSetup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ($AllExtras) { $DisableVolumeKeys = $HideSoundSettings = $BlockSndVol = $HideScaVolume = [switch]$true }

function Find-SourceDir {
    $candidates = @()
    if ($SourceDir) { $candidates += $SourceDir }
    $candidates += $PSScriptRoot
    $candidates += (Join-Path $PSScriptRoot '..\..\windows\artifacts\win-x64')
    foreach ($dir in $candidates) {
        if ((Test-Path (Join-Path $dir $script:ServiceExe)) -and (Test-Path (Join-Path $dir $script:CliExe))) {
            return (Resolve-Path $dir).Path
        }
    }
    throw "Could not find $($script:ServiceExe) and $($script:CliExe). Build them with windows\publish.ps1 or pass -SourceDir."
}

function Install-Binaries([string]$From) {
    Write-Host "Copying binaries to $script:InstallDir"
    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    Copy-Item (Join-Path $From $script:ServiceExe) $script:InstallDir -Force
    Copy-Item (Join-Path $From $script:CliExe) $script:InstallDir -Force

    # SYSTEM full control; Administrators and Users read/execute only. The (OI)(CI) rules are inherited by
    # the files. Do NOT add /T: icacls then applies the folder rules to each file, fails on them after
    # stripping their inherited entries, and leaves the files with an empty DACL nobody can run.
    # The service makes SYSTEM the owner when it starts: an administrator cannot assign ownership to
    # another account, but SYSTEM can take it for itself.
    $r = Invoke-Native icacls.exe $script:InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)RX' '*S-1-5-32-545:(OI)(CI)RX' /C /Q
    if ($r.ExitCode -ne 0) { throw "icacls failed to set permissions on $($script:InstallDir): $($r.Output)" }
    foreach ($exe in $script:ServiceExe, $script:CliExe) {
        $path = Join-Path $script:InstallDir $exe
        try { [IO.File]::OpenRead($path).Dispose() }
        catch { throw "After setting permissions, $path is not readable: $($_.Exception.Message)" }
    }
}

function Register-EventSource {
    # .NET Framework's EventLogMessages.dll ships with Windows and renders every event ID as plain text.
    $messageFile = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\EventLogMessages.dll'
    $key = (Get-HKLM).CreateSubKey($script:EventLogKey)
    try {
        if (Test-Path $messageFile) { $key.SetValue('EventMessageFile', $messageFile, 'ExpandString') }
    } finally { $key.Dispose() }
}

function Register-Service {
    $exe = Join-Path $script:InstallDir $script:ServiceExe
    Write-Host "Registering service $script:ServiceName (automatic, LocalSystem)"
    Invoke-Sc create $script:ServiceName "binPath=" "`"$exe`"" "start=" auto "obj=" LocalSystem "depend=" Audiosrv "DisplayName=" 'SteadyVolume'
    Invoke-Sc description $script:ServiceName 'Locks the master output volume at a fixed level. Control it with steadyvol.exe.'
    # Restart immediately on the first, second and every later failure. The failure count resets after a day,
    # and since every action is "restart" that makes the policy indefinite.
    Invoke-Sc failure $script:ServiceName "reset=" 86400 "actions=" 'restart/0/restart/0/restart/0'
    # Also treat a stop with a non-zero exit code as a failure.
    Invoke-Sc failureflag $script:ServiceName 1
    Invoke-Sc sdset $script:ServiceName $script:DefaultServiceSddl
}

function Add-ToMachinePath {
    $current = [string](Get-RegistryValue $script:MachineEnvKey 'Path')
    if (($current -split ';') -contains $script:InstallDir) { return }
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    Set-RegistryValue $script:MachineEnvKey 'Path' (($current.TrimEnd(';') + ';' + $script:InstallDir)) $kind
    # Uninstall removes just this entry, so later PATH edits by other software are kept.
    Set-RegistryValue $script:BackupKey 'PathEntryAdded' 1 ([Microsoft.Win32.RegistryValueKind]::DWord)
}

function Enable-DisableVolumeKeys {
    Write-Host 'Disabling the Volume Up and Volume Down keys (Scancode Map). Mute stays enabled. Reboot required.'
    Backup-RegistryValue 'ScancodeMap' $script:KeyboardLayoutKey 'Scancode Map'
    $existing = Get-ScancodeMapEntries ([byte[]](Get-RegistryValue $script:KeyboardLayoutKey 'Scancode Map'))
    $entries = [System.Collections.Generic.List[uint32]]::new()
    foreach ($e in $existing) {
        $oldCode = [uint32][math]::Floor($e / 65536)
        if ($script:VolumeScancodes -notcontains $oldCode) { $entries.Add($e) }
    }
    foreach ($code in $script:VolumeScancodes) {
        $entries.Add([uint32]([uint64]$code * 65536)) # new scancode 0x0000 = key does nothing
    }
    Set-RegistryValue $script:KeyboardLayoutKey 'Scancode Map' (New-ScancodeMap $entries.ToArray()) ([Microsoft.Win32.RegistryValueKind]::Binary)
}

function Enable-HideSoundSettings {
    Write-Host 'Hiding the Sound pages in Settings (SettingsPageVisibility).'
    $current = [string](Get-RegistryValue $script:ExplorerPolicyKey 'SettingsPageVisibility')
    if ($current -match '^\s*showonly:(.*)$') {
        $pages = @($Matches[1] -split ';' | Where-Object { $_ -and ($script:SoundSettingsPages -notcontains $_.Trim()) })
        $value = 'showonly:' + ($pages -join ';')
    } elseif ([string]::IsNullOrWhiteSpace($current) -or $current -match '^\s*hide:') {
        $pages = @()
        if ($current -match '^\s*hide:(.*)$') { $pages = @($Matches[1] -split ';' | Where-Object { $_ }) }
        foreach ($p in $script:SoundSettingsPages) { if ($pages -notcontains $p) { $pages += $p } }
        $value = 'hide:' + ($pages -join ';')
    } else {
        Write-Warning "SettingsPageVisibility has an unrecognised value '$current'; leaving it unchanged."
        return
    }
    Backup-RegistryValue 'SettingsPageVisibility' $script:ExplorerPolicyKey 'SettingsPageVisibility'
    Set-RegistryValue $script:ExplorerPolicyKey 'SettingsPageVisibility' $value ([Microsoft.Win32.RegistryValueKind]::String)
}

function Enable-BlockSndVol {
    Write-Host 'Blocking SndVol.exe (Image File Execution Options).'
    Backup-RegistryValue 'SndVolIfeo' $script:SndVolIfeoKey 'Debugger'
    # systray.exe is a stub that exits immediately, so launching SndVol silently does nothing.
    $stub = Join-Path $env:SystemRoot 'System32\systray.exe'
    Set-RegistryValue $script:SndVolIfeoKey 'Debugger' "`"$stub`"" ([Microsoft.Win32.RegistryValueKind]::String)
}

function Enable-HideScaVolume {
    Write-Host 'Setting HideSCAVolume (best effort; ignored by Windows 11 24H2 and later).'
    Backup-RegistryValue 'HideSCAVolume' $script:ExplorerPolicyKey 'HideSCAVolume'
    Set-RegistryValue $script:ExplorerPolicyKey 'HideSCAVolume' 1 ([Microsoft.Win32.RegistryValueKind]::DWord)
}

# ---------------------------------------------------------------------------------------------------

if (Test-ServiceInstalled) {
    throw "The $script:ServiceName service is already installed. Run uninstall.ps1 first (after 'steadyvol unprotect')."
}

$from = Find-SourceDir
Install-Binaries $from
Register-EventSource
Register-Service
Add-ToMachinePath

if ($DisableVolumeKeys) { Enable-DisableVolumeKeys }
if ($HideSoundSettings) { Enable-HideSoundSettings }
if ($BlockSndVol)       { Enable-BlockSndVol }
if ($HideScaVolume)     { Enable-HideScaVolume }

Write-Host 'Starting the service'
Start-Service -Name $script:ServiceName
(Get-Service -Name $script:ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

$cli = Join-Path $script:InstallDir $script:CliExe
Write-Host ''
if ($SkipSetup) {
    Write-Warning "Password setup skipped. Run '$cli setup' now: until a password exists, anyone on this PC could set it."
} else {
    Write-Host 'First-run setup: choose the SteadyVolume password.'
    Write-Host 'Until a password exists, anyone on this PC could set it, so do this now.'
    & $cli setup
}
if ($SkipSetup) {
    # Nothing more to do.
} elseif ($LASTEXITCODE -ne 0) {
    Write-Warning "Setup did not complete. Run '$cli setup' as soon as possible."
} elseif ($Level -ge 0) {
    & $cli lock $Level
} elseif ($LockCurrentLevels) {
    & $cli lock
}

Write-Host ''
Write-Host 'SteadyVolume is installed.'
Write-Host "  Control tool: $cli (added to the system PATH for new terminals)"
Write-Host '  Lock at the current levels (changes nothing):   steadyvol lock'
Write-Host '  Check status:      steadyvol status'
if ($DisableVolumeKeys) { Write-Host '  Reboot to apply the volume key change.' }
