#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs the SteadyVolume end-to-end test on THIS PC (for when Windows Sandbox is unavailable).

.DESCRIPTION
    Installs the real service, attacks it, then unprotects and uninstalls it and checks every
    change was reverted. Safeguards (see SandboxTest.ps1 -HostMode):
      - refuses to run if SteadyVolume is already present
      - no volume-key remap, so no reboot
      - locks at 20% and never sets the volume above 40%
      - saves the registry state to before.json first
      - uninstalls automatically if the test stops part-way
      - restores your original volume and mute at the end
    Takes about 2 minutes.

    By default the test NEVER changes any volume or mute: it locks only with "steadyvol lock" (every
    device held at its current level), skips the probes and the revert tests, and a read-only guard
    aborts (unprotect + uninstall) if any output device's volume or mute differs from the start. -AllowVolumeChange runs the full test instead
    (locks at 20%, changes volumes up to 40% and restores only the default device afterwards).

    Results go to windows\artifacts\host-test\<timestamp>\report.txt.
#>
[CmdletBinding()]
param([switch]$AllowVolumeChange)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bin = Join-Path $repo 'windows\artifacts\win-x64'
foreach ($exe in 'steadyvolume-service.exe', 'steadyvol.exe') {
    if (-not (Test-Path (Join-Path $bin $exe))) { throw "Missing $bin\$exe. Run windows\publish.ps1 first." }
}

$results = Join-Path $repo ('windows\artifacts\host-test\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $results | Out-Null

$modeArgs = @('-HostMode')
if (-not $AllowVolumeChange) { $modeArgs += '-NoVolumeChange' }

# Windows PowerShell 5.1, like most real installs, and the same engine the Sandbox test uses.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'SandboxTest.ps1') @modeArgs `
    -Bin $bin `
    -Install (Join-Path $repo 'install\windows') `
    -Tools (Join-Path $repo 'windows\tools') `
    -Results $results

Get-Content (Join-Path $results 'report.txt')
$summary = Get-Content (Join-Path $results 'done.json') -Raw | ConvertFrom-Json
Write-Host ''
Write-Host "Result: $($summary.result)  (pass $($summary.pass), fail $($summary.fail), skip $($summary.skip))"
Write-Host "Report: $(Join-Path $results 'report.txt')"
