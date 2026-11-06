# Shared helpers for install.ps1 and uninstall.ps1. Dot-source only.

Set-StrictMode -Version Latest

$script:ServiceName   = 'SteadyVolume'
$script:InstallDir    = Join-Path $env:ProgramFiles 'SteadyVolume'
$script:ConfigDir     = Join-Path $env:ProgramData 'SteadyVolume'
$script:ServiceExe    = 'steadyvolume-service.exe'
$script:CliExe        = 'steadyvol.exe'
$script:ProductKey    = 'SOFTWARE\SteadyVolume'
$script:BackupKey     = 'SOFTWARE\SteadyVolume\InstallBackup'
$script:EventLogKey   = 'SYSTEM\CurrentControlSet\Services\EventLog\Application\SteadyVolume'

# Must match ServiceProtection.DefaultDacl in the service: Windows default plus full control for SYSTEM,
# so the service can later tighten (and restore) its own DACL.
$script:DefaultServiceSddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)'

# Registry locations touched by the optional extras.
$script:KeyboardLayoutKey = 'SYSTEM\CurrentControlSet\Control\Keyboard Layout'
$script:ExplorerPolicyKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$script:SndVolIfeoKey     = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SndVol.exe'
$script:MachineEnvKey     = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

# Settings pages hidden by -HideSoundSettings (ms-settings:<name>).
$script:SoundSettingsPages = @('sound', 'sound-devices', 'sound-defaultoutputproperties', 'sound-defaultinputproperties', 'apps-volume')

# Volume Down = E0 2E, Volume Up = E0 30. Mute (E0 20) is deliberately left alone.
$script:VolumeScancodes = @(0xE02E, 0xE030)

function Get-HKLM { [Microsoft.Win32.Registry]::LocalMachine }

function Backup-RegistryValue {
    <# Records the current state of a value once, before we first change it. #>
    param([string]$Id, [string]$KeyPath, [string]$ValueName)
    $backup = (Get-HKLM).CreateSubKey($script:BackupKey)
    try {
        if ($null -ne $backup.GetValue("$Id.Applied")) { return } # keep the true original
        $key = (Get-HKLM).OpenSubKey($KeyPath)
        $existing = if ($key) { $key.GetValue($ValueName, $null, 'DoNotExpandEnvironmentNames') } else { $null }
        if ($null -ne $existing) {
            $backup.SetValue("$Id.Original", $existing, $key.GetValueKind($ValueName))
            $backup.SetValue("$Id.Existed", 1, 'DWord')
        } else {
            $backup.SetValue("$Id.Existed", 0, 'DWord')
        }
        $backup.SetValue("$Id.KeyExisted", [int]($null -ne $key), 'DWord')
        $backup.SetValue("$Id.Applied", 1, 'DWord')
        if ($key) { $key.Dispose() }
    } finally {
        $backup.Dispose()
    }
}

function Restore-RegistryValue {
    <# Puts a value back the way Backup-RegistryValue found it. Returns $true if anything was restored. #>
    param([string]$Id, [string]$KeyPath, [string]$ValueName)
    $backup = (Get-HKLM).OpenSubKey($script:BackupKey, $true)
    if (-not $backup) { return $false }
    try {
        if ($backup.GetValue("$Id.Applied") -ne 1) { return $false }
        if ($backup.GetValue("$Id.Existed") -eq 1) {
            $key = (Get-HKLM).CreateSubKey($KeyPath)
            $key.SetValue($ValueName, $backup.GetValue("$Id.Original", $null, 'DoNotExpandEnvironmentNames'), $backup.GetValueKind("$Id.Original"))
            $key.Dispose()
        } else {
            $key = (Get-HKLM).OpenSubKey($KeyPath, $true)
            if ($key) {
                $key.DeleteValue($ValueName, $false)
                $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
                $key.Dispose()
                if ($empty -and $backup.GetValue("$Id.KeyExisted") -eq 0) {
                    (Get-HKLM).DeleteSubKey($KeyPath, $false)
                }
            }
        }
        foreach ($suffix in 'Original', 'Existed', 'KeyExisted', 'Applied') {
            $backup.DeleteValue("$Id.$suffix", $false)
        }
        return $true
    } finally {
        $backup.Dispose()
    }
}

function Set-RegistryValue {
    param([string]$KeyPath, [string]$ValueName, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    $key = (Get-HKLM).CreateSubKey($KeyPath)
    try { $key.SetValue($ValueName, $Value, $Kind) } finally { $key.Dispose() }
}

function Get-RegistryValue {
    param([string]$KeyPath, [string]$ValueName)
    $key = (Get-HKLM).OpenSubKey($KeyPath)
    if (-not $key) { return $null }
    try { return $key.GetValue($ValueName, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Dispose() }
}

function Get-ScancodeMapEntries {
    <# Parses a Scancode Map value into its mapping DWORDs (header and terminator removed). #>
    param([byte[]]$Data)
    $entries = [System.Collections.Generic.List[uint32]]::new()
    if (-not $Data -or $Data.Length -lt 16) { return ,$entries }
    $count = [BitConverter]::ToUInt32($Data, 8)
    for ($i = 0; $i -lt $count - 1; $i++) {
        $offset = 12 + 4 * $i
        if ($offset + 4 -gt $Data.Length) { break }
        $entry = [BitConverter]::ToUInt32($Data, $offset)
        if ($entry -ne 0) { $entries.Add($entry) }
    }
    return ,$entries
}

function New-ScancodeMap {
    param([uint32[]]$Entries)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $bytes.AddRange([byte[]]::new(8))                                         # version + flags
    $bytes.AddRange([BitConverter]::GetBytes([uint32]($Entries.Count + 1)))   # mappings + terminator
    foreach ($e in $Entries) { $bytes.AddRange([BitConverter]::GetBytes([uint32]$e)) }
    $bytes.AddRange([byte[]]::new(4))                                         # terminator
    return ,$bytes.ToArray()
}

function Test-ServiceInstalled {
    return $null -ne (Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue)
}

function Invoke-Native {
    <#
        Runs a native tool and returns its exit code and combined output. Windows PowerShell 5.1 turns
        anything a native tool writes to stderr into an error record, which aborts the script when
        $ErrorActionPreference is 'Stop'. Callers decide on failure from the exit code instead.
    #>
    param([string]$FilePath, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (($output | Where-Object { $_ }) -join ' ') }
}

function Invoke-Sc {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $r = Invoke-Native sc.exe @Arguments
    if ($r.ExitCode -ne 0) {
        throw "sc.exe $($Arguments -join ' ') failed with exit code $($r.ExitCode): $($r.Output)"
    }
}
