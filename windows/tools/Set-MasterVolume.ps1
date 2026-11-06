<#
.SYNOPSIS
    Manual test helper: sets the default output device's master volume through the Core Audio API
    (IAudioEndpointVolume), then reads it back to show whether SteadyVolume reverted it.

.EXAMPLE
    .\Set-MasterVolume.ps1 -Level 90
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(0, 100)][int]$Level,
    [int]$CheckAfterMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'

if (-not ('SteadyVolumeTest.CoreAudio' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'CoreAudioTest.cs')
}

$before = [SteadyVolumeTest.CoreAudio]::Get()
[SteadyVolumeTest.CoreAudio]::Set($Level)
$immediately = [SteadyVolumeTest.CoreAudio]::Get()
Start-Sleep -Milliseconds $CheckAfterMilliseconds
$after = [SteadyVolumeTest.CoreAudio]::Get()

Write-Host "Before: $before%  Set to: $Level%  Read back immediately: $immediately%  After $CheckAfterMilliseconds ms: $after%"
if ($after -ne $Level) { Write-Host 'The change was reverted.' } else { Write-Host 'The change was NOT reverted.' }
