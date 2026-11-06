#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Removes SteadyVolume and reverts every change install.ps1 made.

.DESCRIPTION
    Tamper protection must be removed first with "steadyvol unprotect" (password required);
    otherwise Windows refuses to stop the service and this script stops without changing anything.

.PARAMETER KeepConfig
    Keep C:\ProgramData\SteadyVolume (password hash and lock settings).
#>
[CmdletBinding()]
param([switch]$KeepConfig)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Remove-ProtectedDirectory([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Write-Host "Removing $Path"
    # These folders are owned by SYSTEM with read-only access for Administrators. takeown uses the
    # take-ownership privilege, so it works even though Administrators have no WRITE_OWNER right.
    # As owner, Administrators can then reset the DACL and delete. Administrators can list both
    # folders, so takeown never needs to prompt.
    $r = Invoke-Native takeown.exe /F $Path /A /R
    if ($r.ExitCode -ne 0) { throw "takeown failed on ${Path}: $($r.Output)" }
    $r = Invoke-Native icacls.exe $Path /reset /T /C /Q
    if ($r.ExitCode -ne 0) { throw "icacls /reset failed on ${Path}: $($r.Output)" }
    $r = Invoke-Native icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q
    if ($r.ExitCode -ne 0) { throw "icacls /grant failed on ${Path}: $($r.Output)" }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

# 1. Stop and delete the service.
if (Test-ServiceInstalled) {
    $service = Get-Service -Name $script:ServiceName
    if ($service.Status -ne 'Stopped') {
        Write-Host 'Stopping the service'
        $r = Invoke-Native sc.exe stop $script:ServiceName
        if ($r.ExitCode -eq 5) {
            Write-Warning ("Access denied: tamper protection is on. Run 'steadyvol unprotect' (password required), " +
                           'then run this script again. Nothing was changed.')
            exit 1
        }
        if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 1062) { throw "Could not stop the service: $($r.Output)" }
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Write-Host 'Deleting the service'
    Invoke-Sc delete $script:ServiceName
} else {
    Write-Host 'Service not installed; cleaning up the remaining pieces.'
}

# 2. Revert the optional extras and PATH.
$rebootNeeded = $false
if (Restore-RegistryValue 'ScancodeMap' $script:KeyboardLayoutKey 'Scancode Map') {
    Write-Host 'Restored the original keyboard Scancode Map (reboot required).'
    $rebootNeeded = $true
}
if (Restore-RegistryValue 'SettingsPageVisibility' $script:ExplorerPolicyKey 'SettingsPageVisibility') {
    Write-Host 'Restored SettingsPageVisibility.'
}
if (Restore-RegistryValue 'SndVolIfeo' $script:SndVolIfeoKey 'Debugger') {
    Write-Host 'Unblocked SndVol.exe.'
}
if (Restore-RegistryValue 'HideSCAVolume' $script:ExplorerPolicyKey 'HideSCAVolume') {
    Write-Host 'Restored HideSCAVolume.'
}
if ((Get-RegistryValue $script:BackupKey 'PathEntryAdded') -eq 1) {
    # Remove only our entry, so PATH changes made by other software since install are kept.
    $current = [string](Get-RegistryValue $script:MachineEnvKey 'Path')
    $kept = @($current -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $script:InstallDir.TrimEnd('\')) })
    Set-RegistryValue $script:MachineEnvKey 'Path' ($kept -join ';') ([Microsoft.Win32.RegistryValueKind]::ExpandString)
    Write-Host "Removed $script:InstallDir from the system PATH."
}

# 3. Event Log source (the log entries themselves stay in the Application log).
(Get-HKLM).DeleteSubKeyTree($script:EventLogKey, $false)

# 4. Files.
Remove-ProtectedDirectory $script:InstallDir
if ($KeepConfig) {
    Write-Host "Keeping $script:ConfigDir"
} else {
    Remove-ProtectedDirectory $script:ConfigDir
}

(Get-HKLM).DeleteSubKeyTree($script:ProductKey, $false)

Write-Host 'SteadyVolume has been uninstalled.'
if ($rebootNeeded) { Write-Host 'Reboot to re-enable the volume keys.' }
