<#
.SYNOPSIS
    Runs the full SteadyVolume install/attack/uninstall test inside Windows Sandbox.

.DESCRIPTION
    Publishes the exes (unless -NoPublish), writes a .wsb configuration that maps the exes, install
    scripts, test tools and this harness read-only into the sandbox plus one writable results folder,
    and opens Windows Sandbox. SandboxTest.ps1 runs automatically at logon. This script waits for
    done.json and prints the report. Nothing is installed or changed on the host.

    Close the Windows Sandbox window afterwards; everything inside it is discarded. You can try the
    taskbar slider and Settings by hand before closing it (the test re-locks at 30% before uninstalling,
    so lock it again with "steadyvol lock 30" after reinstalling if you want to play).
#>
[CmdletBinding()]
param(
    [switch]$NoPublish,
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$artifacts = Join-Path $repo 'windows\artifacts\win-x64'

if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) {
    throw 'Windows Sandbox is already running. Close it first (only one sandbox can run at a time).'
}

if (-not $NoPublish -or -not (Test-Path (Join-Path $artifacts 'steadyvolume-service.exe'))) {
    & (Join-Path $repo 'windows\publish.ps1') | Out-Null
}

$results = Join-Path $repo ('windows\artifacts\sandbox-results\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $results | Out-Null

function Map([string]$HostFolder, [string]$SandboxFolder, [bool]$ReadOnly) {
    $escaped = [Security.SecurityElement]::Escape($HostFolder)
    "    <MappedFolder><HostFolder>$escaped</HostFolder><SandboxFolder>$SandboxFolder</SandboxFolder><ReadOnly>$($ReadOnly.ToString().ToLower())</ReadOnly></MappedFolder>"
}

$maps = @(
    (Map $artifacts 'C:\SV\bin' $true),
    (Map (Join-Path $repo 'install\windows') 'C:\SV\install' $true),
    (Map (Join-Path $repo 'windows\tools') 'C:\SV\tools' $true),
    (Map $PSScriptRoot 'C:\SV\harness' $true),
    (Map $results 'C:\SV\results' $false)
) -join "`r`n"

$wsb = @"
<Configuration>
  <Networking>Disable</Networking>
  <vGPU>Disable</vGPU>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
$maps
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SV\harness\SandboxTest.ps1</Command>
  </LogonCommand>
</Configuration>
"@

$wsbPath = Join-Path $results 'SteadyVolumeTest.wsb'
Set-Content -Path $wsbPath -Value $wsb -Encoding UTF8
Write-Host "Results folder: $results"
Write-Host 'Starting Windows Sandbox...'
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe') -ArgumentList "`"$wsbPath`""

$done = Join-Path $results 'done.json'
$report = Join-Path $results 'report.txt'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$shown = 0
while (-not (Test-Path $done)) {
    if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes minutes. Partial report: $report" }
    if (Test-Path $report) {
        $lines = @(Get-Content $report)
        if ($lines.Count -gt $shown) { $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }; $shown = $lines.Count }
    }
    Start-Sleep -Seconds 2
}

$lines = @(Get-Content $report)
if ($lines.Count -gt $shown) { $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host $_ } }
$summary = Get-Content $done -Raw | ConvertFrom-Json
Write-Host ''
Write-Host "Result: $($summary.result)  (pass $($summary.pass), fail $($summary.fail), skip $($summary.skip))"
Write-Host "Report: $report"
if ($summary.result -ne 'pass') { exit 1 }
