#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Checks that audio control works as LocalSystem in session 0, the context the service runs in.

.DESCRIPTION
    Registers a temporary scheduled task that runs "steadyvolume-service.exe --probe" once as SYSTEM,
    prints its report, then deletes the task and the report. The probe moves the default output
    device's volume by 1% and puts it back. Nothing else on the system is changed.

.PARAMETER ServiceExe
    Path to steadyvolume-service.exe. Defaults to the published or Debug build in the repository.
#>
[CmdletBinding()]
param([string]$ServiceExe)

$ErrorActionPreference = 'Stop'

if (-not $ServiceExe) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'steadyvolume-service.exe'),
        (Join-Path $PSScriptRoot '..\..\windows\artifacts\win-x64\steadyvolume-service.exe'),
        (Join-Path $PSScriptRoot '..\..\windows\src\SteadyVolume.Service\bin\Debug\net10.0-windows\steadyvolume-service.exe')
    )
    $ServiceExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ServiceExe) { throw 'steadyvolume-service.exe not found. Build first or pass -ServiceExe.' }
}
$ServiceExe = (Resolve-Path $ServiceExe).Path

$work = Join-Path $env:ProgramData ('SteadyVolumeProbe-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path $work 'report.txt'
$taskName = 'SteadyVolumeProbe-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
New-Item -ItemType Directory -Path $work | Out-Null

try {
    $action = New-ScheduledTaskAction -Execute $ServiceExe -Argument "--probe `"$report`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
    Write-Host "Running the probe as SYSTEM (task $taskName)..."
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $state = (Get-ScheduledTask -TaskName $taskName).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    $info = Get-ScheduledTaskInfo -TaskName $taskName
    if (Test-Path $report) {
        Get-Content $report
    } else {
        Write-Warning "No report was written. Task result code: $($info.LastTaskResult)"
    }
    Write-Host "Probe exit code: $($info.LastTaskResult) (0 = PASS)"
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
