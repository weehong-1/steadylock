# Builds self-contained single-file x64 executables into windows\artifacts\win-x64.
# Trimming stays off: it can break NAudio's COM interop.
[CmdletBinding()]
param([string]$Configuration = 'Release')

$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'artifacts\win-x64'
$common = @(
    '-c', $Configuration,
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-p:PublishSingleFile=true',
    '-p:PublishTrimmed=false',
    '-p:EnableCompressionInSingleFile=true',
    '-p:DebugType=none',
    '-o', $out
)

foreach ($project in 'src\SteadyVolume.Service', 'src\SteadyVolume.Cli') {
    dotnet publish (Join-Path $PSScriptRoot $project) @common
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $project" }
}

Get-ChildItem $out | Format-Table Name, Length
