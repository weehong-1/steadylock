<#
    End-to-end test: installs SteadyVolume, attacks it the ways an administrator would, then
    uninstalls and checks everything was reverted. Writes report.txt, before.json and done.json.

    Default (no -HostMode): runs INSIDE Windows Sandbox, started by the .wsb LogonCommand, with all
    four extras including the volume-key remap. Locks at 30% and tests with levels up to 100%.

    -HostMode (use Invoke-HostTest.ps1): runs on a real PC.
      * refuses to start if any part of SteadyVolume is already present
      * skips the volume-key remap (no reboot needed)
      * locks at 20% and never sets the volume above 40%
      * saves the registry state to before.json before installing
      * if the test stops part-way, unprotects and uninstalls automatically
      * restores the original volume and mute at the end

    -NoVolumeChange (Invoke-HostTest.ps1 default): never writes any volume or mute and skips the probes
    and the revert tests. It only ever locks with "steadyvol lock" (no level), which holds every device
    at its current level and changes nothing. A read-only guard snapshots every output device's volume
    and mute first, re-checks at each stage, and aborts (unprotect + uninstall) on any difference.
#>
param(
    [switch]$HostMode,
    [switch]$NoVolumeChange,
    [string]$Bin     = 'C:\SV\bin',
    [string]$Install = 'C:\SV\install',
    [string]$Tools   = 'C:\SV\tools',
    [string]$Results = 'C:\SV\results',
    [string]$Local   = 'C:\SVlocal'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Report    = "$Results\report.txt"
$Password  = 'Sandbox-Test-Pass-1'
$Password2 = 'Sandbox-Test-Pass-2'
$Cli       = 'C:\Program Files\SteadyVolume\steadyvol.exe'
$Service   = 'SteadyVolume'

if ($HostMode) {
    $LockLevel    = 20
    $RevertLevels = 35, 0, 40, 21, 19
    $BurstBase    = 22   # burst uses 22-36%
    $HelperLevel  = 40
    $AfterKill    = 33
    $FreeLevel    = 25
} else {
    $LockLevel    = 30
    $RevertLevels = 90, 0, 100, 31, 29
    $BurstBase    = 50   # burst uses 50-69%
    $HelperLevel  = 85
    $AfterKill    = 77
    $FreeLevel    = 64
}
$L = $LockLevel
$Touch = -not $NoVolumeChange   # false = never write any volume/mute and never lock
$script:VolumeBaseline = $null

$script:Counts = @{ PASS = 0; FAIL = 0; SKIP = 0; INFO = 0 }
$script:InstalledByUs = $false

function Log([string]$Kind, [string]$Text) {
    $script:Counts[$Kind]++
    $line = '{0} {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Kind, $Text
    Add-Content -Path $Report -Value $line -Encoding UTF8
}
function Pass([string]$t) { Log 'PASS' $t }
function Fail([string]$t) { Log 'FAIL' $t }
function Skip([string]$t) { Log 'SKIP' $t }
function Info([string]$t) { Log 'INFO' $t }
function Check([bool]$ok, [string]$t) { if ($ok) { Pass $t } else { Fail $t } }
function Section([string]$t) { Add-Content -Path $Report -Value "`r`n== $t" -Encoding UTF8 }

# Runs steadyvol with the given stdin lines; returns @{ Code; Output }.
# Windows PowerShell 5.1 turns a native tool's stderr into error records, which abort the script under
# $ErrorActionPreference = 'Stop'. steadyvol writes expected failures (wrong password, lockout) to
# stderr, so every native call here runs with 'Continue' and is judged by its exit code.
function Invoke-Cli([string[]]$Arguments, [string[]]$StdinLines = @()) {
    $ErrorActionPreference = 'Continue'
    $output = if ($StdinLines.Count -gt 0) { $StdinLines | & $Cli @Arguments 2>&1 } else { & $Cli @Arguments 2>&1 }
    return @{ Code = $LASTEXITCODE; Output = (($output | ForEach-Object { "$_" }) -join ' | ') }
}

function Invoke-Sc([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & sc.exe @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = (($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' | ') }
}

function Stop-ProcessHard([int]$ProcessId) {
    $ErrorActionPreference = 'Continue'
    & taskkill.exe /f /pid $ProcessId 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-NativeQuiet([scriptblock]$Block) {
    $ErrorActionPreference = 'Continue'
    & $Block
}

function Get-ServicePid {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Service'"
    if ($svc -and $svc.State -eq 'Running') { return [int]$svc.ProcessId }
    return 0
}

function Wait-ServiceRunning([int]$OldPid, [int]$TimeoutSeconds = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $p = Get-ServicePid
        if ($p -ne 0 -and $p -ne $OldPid) {
            # Give the pipe server a moment to start listening.
            for ($i = 0; $i -lt 50; $i++) {
                if ((Invoke-Cli @('status')).Code -eq 0) { break }
                Start-Sleep -Milliseconds 100
            }
            return @{ Pid = $p; Ms = [int]$sw.Elapsed.TotalMilliseconds }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# Sets the volume like any script would, then measures how long until it is back at $Expected.
function Measure-Revert([int]$SetTo, [int]$Expected, [int]$TimeoutMs = 2000) {
    [SteadyVolumeTest.CoreAudio]::Set($SetTo)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ([SteadyVolumeTest.CoreAudio]::Get() -eq $Expected) { return [int]$sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 5
    }
    return -1
}

$SnapshotItems = @(
    @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'; Name = 'Scancode Map' },
    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'SettingsPageVisibility' },
    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAVolume' },
    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SndVol.exe'; Name = 'Debugger' }
)
$ScancodeKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map'
$PageVisKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\SettingsPageVisibility'
$HideScaKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\HideSCAVolume'
$IfeoKey     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SndVol.exe\Debugger'

function Get-Snapshot {
    $snap = [ordered]@{}
    foreach ($item in $SnapshotItems) {
        # Registry API instead of Get-ItemProperty: a missing value must read as $null under StrictMode.
        $value = $null
        $sub = (Get-Item -LiteralPath $item.Key -ErrorAction SilentlyContinue)
        if ($sub) { $value = $sub.GetValue($item.Name, $null, 'DoNotExpandEnvironmentNames') }
        if ($null -eq $value) { $text = '<absent>' }
        elseif ($value -is [byte[]]) { $text = 'hex:' + (($value | ForEach-Object { $_.ToString('X2') }) -join '') }
        else { $text = "$value" }
        $snap["$($item.Key)\$($item.Name)"] = $text
    }
    $snap['IFEO SndVol.exe key exists'] = "$(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SndVol.exe')"
    $path = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').Path
    $snap['Machine PATH (normalised)'] = (($path -split ';' | Where-Object { $_ }) -join ';')
    return $snap
}

# Read-only guard for -NoVolumeChange: every output device must keep its exact volume and mute.
function Assert-VolumesUnchanged([string]$Stage) {
    if ($Touch -or $null -eq $script:VolumeBaseline) { return }
    $now = [SteadyVolumeTest.CoreAudio]::SnapshotAllOutputs()
    $diff = Compare-Object $script:VolumeBaseline $now
    if ($diff) {
        foreach ($d in $diff) { Info "volume guard ($Stage): $($d.SideIndicator) $($d.InputObject)" }
        Fail "volume guard: a device volume or mute changed at stage '$Stage'"
        throw "Volume guard tripped at '$Stage'. Aborting and uninstalling."
    }
    Pass "volume guard: all $($now.Count) output devices unchanged ($Stage)"
}

function Test-SteadyVolumePresent {
    return [bool](Get-Service $Service -ErrorAction SilentlyContinue) -or
           (Test-Path 'C:\Program Files\SteadyVolume') -or
           (Test-Path 'C:\ProgramData\SteadyVolume') -or
           (Test-Path 'HKLM:\SOFTWARE\SteadyVolume')
}

# Host mode safety net: if the test stopped part-way, take protection off and uninstall.
function Invoke-EmergencyCleanup {
    if (-not $script:InstalledByUs -or -not (Test-SteadyVolumePresent)) { return }
    Section 'Emergency cleanup'
    # Unprotecting is only needed if the service is running with protection on. Whatever happens here,
    # carry on to the uninstaller, which handles a stopped or half-installed service by itself.
    if ((Get-Service $Service -ErrorAction SilentlyContinue).Status -eq 'Running' -and (Test-Path $Cli)) {
        foreach ($pw in $Password2, $Password) {
            try {
                $r = Invoke-Cli @('unprotect') @($pw)
                if ($r.Code -eq 4) { Info 'locked out; waiting 31 s'; Start-Sleep -Seconds 31; $r = Invoke-Cli @('unprotect') @($pw) }
                Info "unprotect: exit $($r.Code) $($r.Output)"
                if ($r.Code -eq 0) { break }
            } catch {
                Info "unprotect could not run: $($_.Exception.Message)"
                break
            }
        }
    }
    try {
        & "$Install\uninstall.ps1" *>&1 | ForEach-Object { Info "  $_" }
        Check (-not (Test-SteadyVolumePresent)) 'emergency cleanup removed SteadyVolume'
    } catch {
        Fail "emergency cleanup failed: $($_.Exception.Message). See before.json and the README for manual removal."
    }
}

New-Item -ItemType Directory -Force -Path $Results | Out-Null
Set-Content -Path $Report -Value "SteadyVolume end-to-end test ($(if ($HostMode) { 'this PC' } else { 'Windows Sandbox' })), $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -Encoding UTF8
$result = 'aborted'
$audio = $false
$originalVolume = $null
$originalMute = $null

try {
    # ------------------------------------------------------------------------------------------------
    Section 'Environment'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Info "User $($identity.Name), elevated administrator: $isAdmin, PowerShell $($PSVersionTable.PSVersion), OS $([Environment]::OSVersion.VersionString)"
    if (-not $isAdmin) { throw 'Not running elevated; cannot test the installer.' }
    if ($HostMode -and (Test-SteadyVolumePresent)) {
        throw 'SteadyVolume (or part of it) is already present on this PC. Remove it first; the test only runs on a clean machine.'
    }

    Add-Type -Path "$Tools\CoreAudioTest.cs"
    $audio = [SteadyVolumeTest.CoreAudio]::HasDefaultOutput()
    if ($audio) {
        $originalVolume = [SteadyVolumeTest.CoreAudio]::Get()
        $originalMute = [SteadyVolumeTest.CoreAudio]::GetMute()
        Info "Default output device found. Volume $originalVolume%, muted $originalMute"
    } else {
        Info 'No default output device; audio tests will be skipped.'
    }
    if (-not $Touch) {
        $script:VolumeBaseline = [SteadyVolumeTest.CoreAudio]::SnapshotAllOutputs()
        $script:VolumeBaseline | Set-Content -Path "$Results\volumes-before.txt" -Encoding UTF8
        Info "NO-VOLUME-CHANGE MODE: nothing writes any volume or mute; locks only at the current levels. Guard baseline: $($script:VolumeBaseline.Count) output devices."
    }

    if ($HostMode) {
        $Local = $Bin
    } else {
        New-Item -ItemType Directory -Force -Path $Local | Out-Null
        Copy-Item "$Bin\*.exe" $Local -Force
    }

    # ------------------------------------------------------------------------------------------------
    if ($Touch) {
        Section 'Audio probe in the user session'
        $probeOut = Invoke-NativeQuiet { & "$Local\steadyvolume-service.exe" --probe 2>&1 }
        $probeCode = $LASTEXITCODE
        $probeOut | ForEach-Object { Info "  $_" }
        Check ($probeCode -eq 0) 'probe passes as the logged-on administrator'

        Section 'Audio probe as SYSTEM in session 0 (probe-session0.ps1)'
        $s0 = Invoke-NativeQuiet { & "$Install\probe-session0.ps1" -ServiceExe "$Local\steadyvolume-service.exe" 2>&1 }
        $s0 | ForEach-Object { Info "  $_" }
        $s0Passed = (($s0 | Out-String) -match 'RESULT: PASS' -and ($s0 | Out-String) -match 'Session: 0')
        Check $s0Passed 'probe passes as SYSTEM in session 0'
        if (-not $s0Passed) { throw 'Session 0 cannot control audio; stopping before installing anything.' }
    } else {
        Skip 'audio probes (they nudge the volume by 1%; both already passed on this PC)'
    }

    # ------------------------------------------------------------------------------------------------
    Section 'Install'
    $before = Get-Snapshot
    foreach ($k in $before.Keys) { Info "before: $k = $($before[$k])" }
    $before | ConvertTo-Json | Set-Content -Path "$Results\before.json" -Encoding UTF8

    $script:InstalledByUs = $true
    if ($HostMode) {
        $installOut = & "$Install\install.ps1" -SourceDir $Bin -HideSoundSettings -BlockSndVol -HideScaVolume -SkipSetup *>&1
    } else {
        $installOut = & "$Install\install.ps1" -SourceDir $Bin -AllExtras -SkipSetup *>&1
    }
    $installOut | ForEach-Object { Info "  $_" }
    Check ((Get-Service $Service -ErrorAction SilentlyContinue).Status -eq 'Running') 'service installed and running'

    $svc = Get-CimInstance Win32_Service -Filter "Name='$Service'"
    Check ($svc.StartMode -eq 'Auto') "start mode automatic (is $($svc.StartMode))"
    Check ($svc.StartName -eq 'LocalSystem') "runs as LocalSystem (is $($svc.StartName))"
    $servicePid = Get-ServicePid
    $session = (Get-Process -Id $servicePid).SessionId
    Check ($session -eq 0) "service process is in session $session"
    $qf = Invoke-Sc @('qfailure', $Service)
    Info "qfailure: $($qf.Output)"
    Check (([regex]::Matches($qf.Output, 'RESTART -- Delay = 0 milliseconds')).Count -eq 3) 'recovery: restart after 0 ms on 1st, 2nd and later failures'
    $qff = Invoke-Sc @('qfailureflag', $Service)
    Check ($qff.Output -match 'TRUE') 'failure flag set (non-zero exit counts as failure)'
    Check ((Invoke-Sc @('qc', $Service)).Output -match 'Audiosrv') 'depends on Audiosrv'

    $after = Get-Snapshot
    foreach ($k in $after.Keys) { Info "after install: $k = $($after[$k])" }
    if ($HostMode) {
        Check ($after[$ScancodeKey] -eq $before[$ScancodeKey]) 'Scancode Map untouched (volume-key remap not used on this PC)'
    } else {
        Check ($after[$ScancodeKey] -eq 'hex:00000000000000000300000000002EE0000030E000000000') 'Scancode Map disables only Volume Down and Volume Up'
    }
    Check ($after[$PageVisKey] -match 'hide:.*sound.*apps-volume') 'SettingsPageVisibility hides the sound pages'
    Check ($after[$HideScaKey] -eq '1') 'HideSCAVolume set'
    Check ($after[$IfeoKey] -match 'systray\.exe') 'SndVol.exe redirected to systray.exe'
    Assert-VolumesUnchanged 'after install'

    # ------------------------------------------------------------------------------------------------
    Section 'First-run setup and lock'
    $r = Invoke-Cli @('status')
    Info "status: $($r.Output)"
    Check ($r.Output -match 'not set') 'status before setup shows no password'
    $r = Invoke-Cli @('setup') @($Password, $Password)
    Check ($r.Code -eq 0) "setup creates the password (exit $($r.Code)): $($r.Output)"
    $r = Invoke-Cli @('setup') @('Another-Pass-9', 'Another-Pass-9')
    Check ($r.Code -ne 0) "second setup refused (exit $($r.Code))"
    if ($Touch) {
        $r = Invoke-Cli @('lock', "$L") @($Password)
        Check ($r.Code -eq 0) "lock $L with the password (exit $($r.Code)): $($r.Output)"
        $r = Invoke-Cli @('status')
        Info "status: $($r.Output)"
        Check ($r.Output -match "locked at $L%" -and $r.Output -match 'Protection:\s+on') "status shows locked at $L% with protection on"
    } else {
        $r = Invoke-Cli @('status')
        Check ($r.Output -match 'Lock:\s+unlocked' -and $r.Output -match 'Protection:\s+on') 'status shows unlocked with protection on (setup turns protection on)'
        Assert-VolumesUnchanged 'after setup'

        $r = Invoke-Cli @('lock') @($Password)
        Check ($r.Code -eq 0 -and $r.Output -match 'Nothing was changed') "lock at current levels (exit $($r.Code)): $($r.Output)"
        Start-Sleep -Seconds 2   # let the enforcer make several passes over every device
        Assert-VolumesUnchanged 'after locking at current levels'
        $r = Invoke-Cli @('status')
        Info "status: $($r.Output)"
        $n = $script:VolumeBaseline.Count
        Check ($r.Output -match "locked at current levels \($n device" -and $r.Output -match 'Protection:\s+on') "status shows all $n devices locked at their current levels, protection on"
        $configText = Get-Content 'C:\ProgramData\SteadyVolume\config.json' -Raw | ConvertFrom-Json
        $stored = @($configText.deviceLevels)
        $mismatch = @(foreach ($line in $script:VolumeBaseline) {
            $id, $scalar, $muted = $line -split '\|'
            $s = $stored | Where-Object id -eq $id
            if (-not $s -or [math]::Abs([double]$scalar - [double]$s.scalar) -ge 0.00005) { $id }
        })
        Check ($stored.Count -eq $n -and $mismatch.Count -eq 0) "stored levels match every device's actual level exactly ($($stored.Count) stored, $($mismatch.Count) mismatched)"
    }
    Assert-VolumesUnchanged 'after setup and lock'
    if ($Touch) {
        $r = Invoke-Cli @('lock', "$L", '--password', 'x')
        Check ($r.Code -eq 2) 'passwords given as arguments are rejected'
        $r = Invoke-Cli @('lock', '150') @($Password)
        Check ($r.Code -eq 2) 'lock 150 rejected as usage error'
    } else {
        $r = Invoke-Cli @('unlock', '--password', 'x')
        Check ($r.Code -eq 2) 'passwords given as arguments are rejected'
    }

    # ------------------------------------------------------------------------------------------------
    Section 'Config and program folder permissions'
    $acl = Get-Acl 'C:\ProgramData\SteadyVolume'
    Info "config dir owner $($acl.Owner); rules: $(($acl.Access | ForEach-Object { "$($_.IdentityReference)=$($_.FileSystemRights)" }) -join '; ')"
    Check ($acl.Owner -match 'SYSTEM') 'config folder owned by SYSTEM'
    Check ($acl.AreAccessRulesProtected) 'config folder does not inherit from ProgramData'
    Check (-not ($acl.Access | Where-Object { $_.IdentityReference -match 'Users|Everyone|Authenticated' })) 'no access for users'
    try { Add-Content 'C:\ProgramData\SteadyVolume\config.json' 'x'; Fail 'administrator could write config.json' }
    catch { Pass 'administrator cannot write config.json' }
    $configText = Get-Content 'C:\ProgramData\SteadyVolume\config.json' -Raw
    Check ($configText -match '"iterations": 600000' -and $configText -notmatch $Password) 'administrator can read config.json; it holds a 600000-iteration hash, not the password'
    try { Set-Content 'C:\Program Files\SteadyVolume\evil.txt' 'x'; Fail 'administrator could write to the program folder' }
    catch { Pass 'administrator cannot write to the program folder' }

    # ------------------------------------------------------------------------------------------------
    Section 'Volume enforcement'
    if (-not $Touch) {
        Skip 'enforcement, mute and log-throttle tests (no-volume-change mode)'
    } elseif ($audio) {
        Start-Sleep -Seconds 1
        Check ([SteadyVolumeTest.CoreAudio]::Get() -eq $L) "volume is $L% after lock (is $([SteadyVolumeTest.CoreAudio]::Get())%)"
        $times = @()
        foreach ($level in $RevertLevels) {
            $ms = Measure-Revert $level $L
            $times += $ms
            Check ($ms -ge 0) "script set $level% -> reverted to $L% in $ms ms"
        }
        Info "revert times (ms): $($times -join ', ')"

        $muteBefore = [SteadyVolumeTest.CoreAudio]::GetMute()
        [SteadyVolumeTest.CoreAudio]::SetMute($true)
        Start-Sleep -Milliseconds 800
        Check ([SteadyVolumeTest.CoreAudio]::GetMute() -eq $true) 'mute is left alone (still muted after 800 ms)'
        Check ([SteadyVolumeTest.CoreAudio]::Get() -eq $L) "volume still $L% while muted"
        [SteadyVolumeTest.CoreAudio]::SetMute($false)
        Start-Sleep -Milliseconds 500
        Check ([SteadyVolumeTest.CoreAudio]::GetMute() -eq $false) 'unmute is left alone'
        [SteadyVolumeTest.CoreAudio]::SetMute($muteBefore)

        # Burst: 40 changes in about 2 s should produce only a few event log entries.
        $burstStart = Get-Date
        for ($i = 0; $i -lt 40; $i++) { [SteadyVolumeTest.CoreAudio]::Set($BurstBase + ($i % 15)); Start-Sleep -Milliseconds 50 }
        Start-Sleep -Seconds 1
        Check ([SteadyVolumeTest.CoreAudio]::Get() -eq $L) "volume back at $L% after a burst of 40 changes"
        $burstEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'SteadyVolume'; Id = 3000; StartTime = $burstStart } -ErrorAction SilentlyContinue)
        Check ($burstEvents.Count -le 3) "revert logging is throttled ($($burstEvents.Count) event(s) for 40 changes)"

        $helper = & "$Tools\Set-MasterVolume.ps1" -Level $HelperLevel *>&1
        Info "Set-MasterVolume.ps1: $($helper -join ' ')"
        Check (($helper | Out-String) -match 'was reverted') 'Set-MasterVolume.ps1 reports the change was reverted'
    } else {
        Skip 'no audio device: revert, mute and burst tests'
    }

    # ------------------------------------------------------------------------------------------------
    Section 'Tamper protection (as administrator)'
    $r = Invoke-Sc @('stop', $Service);                                     Check ($r.Code -eq 5) "sc stop denied (exit $($r.Code))"
    $r = Invoke-Sc @('pause', $Service);                                    Check ($r.Code -eq 5) "sc pause denied (exit $($r.Code))"
    $r = Invoke-Sc @('config', $Service, 'start=', 'disabled');             Check ($r.Code -eq 5) "sc config start= disabled denied (exit $($r.Code))"
    $r = Invoke-Sc @('failure', $Service, 'reset=', '0', 'actions=', '""'); Check ($r.Code -eq 5) "sc failure (remove recovery) denied (exit $($r.Code))"
    $r = Invoke-Sc @('sdset', $Service, 'D:(A;;GA;;;BA)');                  Check ($r.Code -eq 5) "sc sdset (rewrite permissions) denied (exit $($r.Code))"
    $r = Invoke-Sc @('delete', $Service);                                   Check ($r.Code -eq 5) "sc delete denied (exit $($r.Code))"
    try { Stop-Service $Service -ErrorAction Stop; Fail 'Stop-Service succeeded' } catch { Pass 'Stop-Service denied' }
    $r = Invoke-Sc @('query', $Service);                                    Check ($r.Code -eq 0) 'sc query still allowed'
    $r = Invoke-Sc @('qc', $Service);                                       Check ($r.Code -eq 0) 'sc qc (query config) still allowed'
    Check ((Get-Service $Service).Status -eq 'Running') 'service still running after all attempts'

    Section 'Killing the process'
    for ($i = 1; $i -le 4; $i++) {
        $old = Get-ServicePid
        $killed = Stop-ProcessHard $old
        $back = Wait-ServiceRunning $old 30
        if (-not $killed) { Fail "kill #${i}: taskkill could not kill PID $old"; break }
        Check ($null -ne $back) "kill #${i}: PID $old killed, restarted as PID $(if ($back) { $back.Pid }) after $(if ($back) { $back.Ms }) ms"
        if (-not $back) { break }
    }
    $r = Invoke-Cli @('status')
    if ($Touch) {
        Check ($r.Output -match "locked at $L%") "still locked at $L% after the restarts"
        if ($audio) {
            $ms = Measure-Revert $AfterKill $L
            Check ($ms -ge 0) "enforcement works after the restarts (reverted in $ms ms)"
        }
    } else {
        Check ($r.Output -match 'locked at current levels' -and $r.Output -match 'Protection:\s+on') 'still locked at current levels and protected after the restarts'
    }
    Assert-VolumesUnchanged 'after the kills'

    # ------------------------------------------------------------------------------------------------
    Section 'Wrong passwords and lockout'
    for ($i = 1; $i -le 4; $i++) {
        $r = Invoke-Cli @('unlock') @('wrong-password')
        Check ($r.Code -eq 3) "wrong password #$i refused (exit $($r.Code)): $($r.Output)"
    }
    $r = Invoke-Cli @('unlock') @('wrong-password')
    Check ($r.Code -eq 4) "wrong password #5 starts the lockout (exit $($r.Code)): $($r.Output)"
    $r = Invoke-Cli @('unlock') @($Password)
    Check ($r.Code -eq 4) "correct password refused during lockout (exit $($r.Code))"
    $r = Invoke-Cli @('status')
    Check ($r.Code -eq 0) 'status still works during lockout'

    $old = Get-ServicePid
    $null = Stop-ProcessHard $old
    $null = Wait-ServiceRunning $old 30
    $r = Invoke-Cli @('unprotect') @($Password)
    Check ($r.Code -eq 4) "lockout survives a service restart (exit $($r.Code)): $($r.Output)"

    # In no-volume-change mode every password check uses 'unlock' (already unlocked, so it changes nothing).
    $AuthCommand = if ($Touch) { @('lock', "$L") } else { @('lock') }

    Info 'waiting 31 s for the lockout to expire'
    Start-Sleep -Seconds 31
    $r = Invoke-Cli $AuthCommand @($Password)
    Check ($r.Code -eq 0) "correct password accepted after the lockout ($($AuthCommand -join ' '), exit $($r.Code))"
    Assert-VolumesUnchanged 'after the lockout tests'

    # ------------------------------------------------------------------------------------------------
    Section 'Change password'
    $r = Invoke-Cli @('passwd') @($Password, 'short', $Password2, $Password2)
    Check ($r.Code -eq 0) "passwd (after one too-short attempt) succeeds (exit $($r.Code)): $($r.Output)"
    $r = Invoke-Cli $AuthCommand @($Password)
    Check ($r.Code -eq 3) 'old password no longer works'
    $r = Invoke-Cli $AuthCommand @($Password2)
    Check ($r.Code -eq 0) 'new password works'

    # ------------------------------------------------------------------------------------------------
    Section 'Unlock'
    $r = Invoke-Cli @('unlock') @($Password2)
    Check ($r.Code -eq 0) "unlock (exit $($r.Code))"
    if ($Touch) {
        if ($audio) {
            [SteadyVolumeTest.CoreAudio]::Set($FreeLevel)
            Start-Sleep -Milliseconds 800
            Check ([SteadyVolumeTest.CoreAudio]::Get() -eq $FreeLevel) 'volume can be changed freely when unlocked'
        }
        $r = Invoke-Cli @('lock', "$L") @($Password2)
        Check ($r.Code -eq 0) 'lock again'
    }
    Assert-VolumesUnchanged 'after password change and unlock'

    # ------------------------------------------------------------------------------------------------
    Section 'Event Log'
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'SteadyVolume' } -ErrorAction SilentlyContinue)
    $ids = $events | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "$($_.Name)x$($_.Count)" }
    Info "event IDs: $($ids -join ', ')"
    $expectedIds = 1000, 1100, 1101, 1102, 1103, 1105, 2000, 2001, 2002
    foreach ($id in $expectedIds) {
        Check (@($events | Where-Object Id -eq $id).Count -gt 0) "event $id logged"
    }
    if ($Touch -and $audio) { Check (@($events | Where-Object Id -eq 3000).Count -gt 0) 'event 3000 (revert) logged' }
    if (-not $Touch) { Check (@($events | Where-Object Id -eq 3000).Count -eq 0) 'no revert events (3000): the service never changed a volume' }
    if ($Touch) {
        $sample = $events | Where-Object Id -eq 1101 | Select-Object -First 1
        Check ($sample -and $sample.Message -match "locked at $L%") "event text renders: '$(if ($sample) { $sample.Message })'"
    } else {
        $sample = $events | Where-Object Id -eq 1101 | Select-Object -First 1
        Check ($sample -and $sample.Message -match 'locked at current levels') "event text renders: '$(if ($sample) { $sample.Message })'"
    }
    $errors = @($events | Where-Object { $_.Level -le 2 })
    foreach ($e in $errors) { Info "error event $($e.Id): $($e.Message)" }

    # ------------------------------------------------------------------------------------------------
    Section 'Unprotect and uninstall'
    $r = Invoke-Cli @('unprotect') @($Password2)
    Check ($r.Code -eq 0) "unprotect (exit $($r.Code)): $($r.Output)"
    $sd = Invoke-Sc @('sdshow', $Service)
    Info "service DACL after unprotect: $($sd.Output)"
    Check ($sd.Output -match '\(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA\)') 'Administrators have full control again'

    $uninstallOut = & "$Install\uninstall.ps1" *>&1
    $uninstallOut | ForEach-Object { Info "  $_" }
    Check ($null -eq (Get-Service $Service -ErrorAction SilentlyContinue)) 'service removed'
    Check (-not (Test-Path 'C:\Program Files\SteadyVolume')) 'program folder removed'
    Check (-not (Test-Path 'C:\ProgramData\SteadyVolume')) 'config folder removed'
    Check (-not (Test-Path 'HKLM:\SOFTWARE\SteadyVolume')) 'install backup key removed'
    Check (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\SteadyVolume')) 'event source removed'

    $final = Get-Snapshot
    foreach ($k in $before.Keys) {
        Check ($final[$k] -eq $before[$k]) "restored: $k ($($final[$k]))"
    }
    Assert-VolumesUnchanged 'after uninstall'

    $result = if ($script:Counts.FAIL -eq 0) { 'pass' } else { 'fail' }
}
catch {
    Fail "harness error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $result = 'error'
    if ($HostMode) { Invoke-EmergencyCleanup }
}
finally {
    if (-not $Touch -and $null -ne $script:VolumeBaseline) {
        # Report only; never write. A difference here means something changed a volume during the run.
        try {
            $end = [SteadyVolumeTest.CoreAudio]::SnapshotAllOutputs()
            $end | Set-Content -Path "$Results\volumes-after.txt" -Encoding UTF8
            if (Compare-Object $script:VolumeBaseline $end) { Fail 'volume guard: final volumes differ from the start (see volumes-before/after.txt)' }
            else { Pass "volume guard: final check, all $($end.Count) output devices exactly as before" }
        } catch { Info "final volume check failed: $($_.Exception.Message)" }
    }
    if ($Touch -and $HostMode -and $audio -and $null -ne $originalVolume) {
        try {
            [SteadyVolumeTest.CoreAudio]::Set($originalVolume)
            [SteadyVolumeTest.CoreAudio]::SetMute($originalMute)
            Info "restored the original volume ($originalVolume%) and mute ($originalMute)"
        } catch {
            Info "could not restore the original volume: $($_.Exception.Message)"
        }
    }
    Section 'Summary'
    Add-Content -Path $Report -Value ("PASS {0}  FAIL {1}  SKIP {2}" -f $script:Counts.PASS, $script:Counts.FAIL, $script:Counts.SKIP) -Encoding UTF8
    @{ result = $result; pass = $script:Counts.PASS; fail = $script:Counts.FAIL; skip = $script:Counts.SKIP } |
        ConvertTo-Json | Set-Content -Path "$Results\done.json" -Encoding UTF8
}
