# orchestrator.ps1 - Juniper Imaging Phase Orchestrator
# Runs as SYSTEM via the JuniperImaging scheduled task (created by SetupComplete.cmd).
# Reads phase.json to determine what to run next, executes the phase script,
# logs the result, advances state, and reboots if needed.
#
# Lifecycle:
#   SetupComplete.cmd --> orchestrator.ps1 -Bootstrap
#     --> creates JuniperImaging scheduled task (AtStartup, SYSTEM)
#     --> arms junadmin autologon + kiosk shell (provision-status.ps1)
#     --> writes initial phase.json + progress.json
#     --> runs first phase immediately
#   Each subsequent boot:
#     JuniperImaging task --> orchestrator.ps1
#       --> re-arms autologon count (so the kiosk survives every reboot)
#       --> reads current phase --> runs phase script --> logs exit code
#       --> exit 3010: reboot (phase stays same, task fires again next boot)
#       --> exit 0:    advance to next phase, run it now (no reboot needed)
#       --> all phases done: tear down kiosk + autologon, remove task, reboot clean
#
# Provisioning lockout (kiosk):
#   During imaging, junadmin auto-logs in and its Winlogon Shell is replaced with
#   provision-status.ps1 (a fullscreen WPF status window) INSTEAD of explorer.exe.
#   The end user sees only the status screen - no desktop, no Start menu = locked out.
#   On completion the orchestrator restores explorer.exe and clears autologon, so the
#   next boot is a normal login screen.  See Set-KioskMode / Remove-KioskMode below.
#
# Logs:
#   C:\ProgramData\JuniperSetup\imaging.log       master log
#   C:\ProgramData\JuniperSetup\logs\<phase>.log  per-phase output
#   C:\ProgramData\JuniperSetup\progress.json     live progress for the status GUI

param([switch]$Bootstrap)

$SetupRoot  = 'C:\ProgramData\JuniperSetup'
$ScriptsDir = "$SetupRoot\scripts"
$PhaseFile  = "$SetupRoot\phase.json"
$ProgressFile = "$SetupRoot\progress.json"
$TaskName   = 'JuniperImaging'
$KioskUser  = 'junadmin'

# Inventory server base URL - the live imaging-progress dashboard ingests our
# progress.json here so a tech can watch this machine image from /deploy/status.
$InvApi = 'http://192.168.5.141:8080'

# Cache machine identity once (serial + hostname + primary MAC) so each progress
# POST can be resolved to this device record (serial-first, same as the agent).
$script:MachineIdentity = $null
function Get-MachineIdentity {
    if ($script:MachineIdentity) { return $script:MachineIdentity }
    $serial = $null; $mac = $null
    try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber } catch {}
    try {
        $nic = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
               Where-Object { $_.PhysicalAdapter -and $_.MACAddress -and $_.NetEnabled } |
               Select-Object -First 1
        if (-not $nic) {
            $nic = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.PhysicalAdapter -and $_.MACAddress } | Select-Object -First 1
        }
        if ($nic) { $mac = $nic.MACAddress }
    } catch {}
    $script:MachineIdentity = [pscustomobject]@{
        serial   = if ($serial) { "$serial".Trim() } else { $null }
        hostname = $env:COMPUTERNAME
        mac      = if ($mac) { "$mac".Replace('-',':').ToLower() } else { $null }
    }
    return $script:MachineIdentity
}

# Best-effort POST of a progress snapshot to the inventory server. Never throws;
# imaging must not depend on the server being reachable.
function Send-ProgressToServer {
    param($Progress)
    try {
        $id = Get-MachineIdentity
        $body = @{
            serial         = $id.serial
            hostname       = $id.hostname
            mac            = $id.mac
            overallPercent = [int]$Progress.overallPercent
            phaseKey       = $Progress.phaseKey
            phaseLabel     = $Progress.phaseLabel
            phaseIndex     = [int]$Progress.phaseIndex
            phaseTotal     = [int]$Progress.phaseTotal
            stepMessage    = $Progress.stepMessage
            state          = $Progress.state
            updatedUtc     = $Progress.updatedUtc
            source         = 'orchestrator'
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$InvApi/ingest/deploy-progress" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 5 -ErrorAction Stop | Out-Null
    } catch {}
}

# Best-effort upload of a finished phase's log file to the inventory server so it
# is viewable from the Imaging tab (/deploy/status). Called at the END of every
# phase (status 'ok') and immediately when a phase fails (status 'error').
# Never throws; imaging must not depend on the server being reachable. Tails the
# last 480 KB if the log is huge (errors live at the end).
function Send-PhaseLog {
    param(
        [Parameter(Mandatory)][string]$PhaseKey,
        [ValidateSet('ok','error')][string]$Status = 'ok'
    )
    try {
        $logPath = "$SetupRoot\logs\$PhaseKey.log"
        $logText = ''
        if (Test-Path $logPath) {
            $bytes = [IO.File]::ReadAllBytes($logPath)
            $cap   = 480 * 1024
            if ($bytes.Length -gt $cap) {
                $tail   = $bytes[($bytes.Length - $cap)..($bytes.Length - 1)]
                $logText = "...[truncated to last 480 KB]...`r`n" + [Text.Encoding]::UTF8.GetString($tail)
            } else {
                $logText = [Text.Encoding]::UTF8.GetString($bytes)
            }
        }
        $id = Get-MachineIdentity
        $body = @{
            serial    = $id.serial
            hostname  = $id.hostname
            mac       = $id.mac
            phase_key = $PhaseKey
            status    = $Status
            log_text  = $logText
            ts        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$InvApi/ingest/deploy-log" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 8 -ErrorAction Stop | Out-Null
    } catch {}
}

# Self-update: pull fresh scripts from the deploy share at the start of every run.
# This lets us hotfix phase scripts (and this orchestrator) without re-imaging.
# Silently skipped if the share is unreachable.
$_shareScripts = '\\192.168.5.141\deploy$\scripts'
if (Test-Path $_shareScripts -ErrorAction SilentlyContinue) {
    try {
        foreach ($f in @('03-windows-update.ps1','04-install-packages.ps1',
                         '07-remove-bloatware.ps1','08-set-file-associations.ps1',
                         'provision-status.ps1')) {
            $s = Join-Path $_shareScripts $f
            if (Test-Path $s) { Copy-Item $s (Join-Path $ScriptsDir $f) -Force -ErrorAction SilentlyContinue }
        }
        # provision-status.ps1 also lives at the root (the kiosk shell points there)
        $psSrc = Join-Path $_shareScripts 'provision-status.ps1'
        if (Test-Path $psSrc) { Copy-Item $psSrc "$SetupRoot\provision-status.ps1" -Force -ErrorAction SilentlyContinue }
        $lgSrc = Join-Path $_shareScripts 'Logging.ps1'
        if (Test-Path $lgSrc) { Copy-Item $lgSrc "$SetupRoot\Logging.ps1" -Force -ErrorAction SilentlyContinue }
        # Update this orchestrator for the NEXT run (safe - already parsed into memory)
        $orchSrc = Join-Path $_shareScripts 'orchestrator.ps1'
        if (Test-Path $orchSrc) { Copy-Item $orchSrc "$SetupRoot\orchestrator.ps1" -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# Phase order: key matches phase.json "phase", value is script filename in $ScriptsDir
$Phases = [ordered]@{
    'windows-update'    = '03-windows-update.ps1'
    'install-packages'  = '04-install-packages.ps1'
    'remove-bloatware'  = '07-remove-bloatware.ps1'
    'file-associations' = '08-set-file-associations.ps1'
}

# Friendly labels + weighted progress bands (overallPercent) per phase.
# Each phase owns a [start,end] slice of the 0-100 bar; "done" = 100.
$PhaseMeta = [ordered]@{
    'windows-update'    = @{ Label = 'Installing Windows updates';        Start = 5;  End = 45 }
    'install-packages'  = @{ Label = 'Installing applications';           Start = 45; End = 80 }
    'remove-bloatware'  = @{ Label = 'Removing unwanted apps';            Start = 80; End = 92 }
    'file-associations' = @{ Label = 'Configuring default applications';  Start = 92; End = 99 }
}

. "$SetupRoot\Logging.ps1"
Initialize-ImagingLogging -PhaseName 'orchestrator'

# ---- Helpers ----------------------------------------------------------------

function Get-PhaseState {
    if (Test-Path $PhaseFile) {
        try { return Get-Content $PhaseFile -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ phase = 'windows-update'; round = 0 }
}

function Save-PhaseState {
    param([string]$Phase, [int]$Round = 0)
    [pscustomobject]@{
        phase   = $Phase
        round   = $Round
        updated = (Get-Date -Format 'o')
    } | ConvertTo-Json | Set-Content $PhaseFile -Encoding UTF8
}

function Get-NextPhase {
    param([string]$Current)
    $keys = @($Phases.Keys)
    $idx  = [array]::IndexOf($keys, $Current)
    if ($idx -lt 0 -or $idx -ge $keys.Count - 1) { return 'done' }
    return $keys[$idx + 1]
}

# ---- Progress JSON for the status GUI ---------------------------------------
# Writes C:\ProgramData\JuniperSetup\progress.json, which provision-status.ps1
# polls ~every 1.5s.  ASCII-safe, UTF8 (no BOM), and readable by Users (the
# kiosk runs in junadmin's session).  Robust if the file is briefly locked.
#
# Schema:
#   overallPercent : int 0-100  (weighted across phases)
#   phaseKey       : current phase key (e.g. 'windows-update') or 'bootstrap'/'done'
#   phaseLabel     : friendly text (e.g. 'Installing Windows updates')
#   phaseIndex     : 1-based index of the current phase
#   phaseTotal     : total number of phases
#   stepMessage    : optional sub-status (set by phase scripts via step file)
#   state          : 'running' | 'rebooting' | 'done' | 'error'
#   updatedUtc     : ISO-8601 UTC timestamp

function Write-ProgressJson {
    param(
        [int]$OverallPercent,
        [string]$PhaseKey,
        [string]$PhaseLabel,
        [int]$PhaseIndex,
        [int]$PhaseTotal,
        [string]$StepMessage = '',
        [ValidateSet('running','rebooting','done','error')][string]$State = 'running'
    )
    $obj = [ordered]@{
        overallPercent = [int]$OverallPercent
        phaseKey       = $PhaseKey
        phaseLabel     = $PhaseLabel
        phaseIndex     = [int]$PhaseIndex
        phaseTotal     = [int]$PhaseTotal
        stepMessage    = $StepMessage
        state          = $State
        updatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $json = $obj | ConvertTo-Json -Compress
    # Write to a temp file then move into place so the GUI never reads a half-written file.
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $tmp = "$ProgressFile.tmp"
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item $tmp $ProgressFile -Force -ErrorAction Stop
            Send-ProgressToServer -Progress $obj
            return
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
}

# Maps a phase + completion fraction (0..1 within the phase) to an overall percent.
function Get-OverallPercent {
    param([string]$PhaseKey, [double]$Fraction = 0.0)
    if (-not $PhaseMeta.Contains($PhaseKey)) { return 5 }
    $m = $PhaseMeta[$PhaseKey]
    $p = $m.Start + ($m.End - $m.Start) * [math]::Max(0.0, [math]::Min(1.0, $Fraction))
    return [int][math]::Round($p)
}

# Phase scripts can drop a one-line sub-status into:
#   C:\ProgramData\JuniperSetup\logs\<phase>.step
# The orchestrator reads it back into progress.json so the GUI shows live detail.
function Read-PhaseStep {
    param([string]$PhaseKey)
    $f = "$SetupRoot\logs\$PhaseKey.step"
    if (Test-Path $f) {
        try { return (Get-Content $f -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    }
    return ''
}

# Convenience: publish progress for a phase at a given fraction + state.
function Publish-PhaseProgress {
    param(
        [string]$PhaseKey,
        [double]$Fraction = 0.0,
        [ValidateSet('running','rebooting','done','error')][string]$State = 'running'
    )
    $keys  = @($Phases.Keys)
    $idx   = [array]::IndexOf($keys, $PhaseKey)
    $label = if ($PhaseMeta.Contains($PhaseKey)) { $PhaseMeta[$PhaseKey].Label } else { 'Setting up this PC' }
    Write-ProgressJson `
        -OverallPercent (Get-OverallPercent -PhaseKey $PhaseKey -Fraction $Fraction) `
        -PhaseKey $PhaseKey -PhaseLabel $label `
        -PhaseIndex ($idx + 1) -PhaseTotal $keys.Count `
        -StepMessage (Read-PhaseStep -PhaseKey $PhaseKey) `
        -State $State
}

# ---- Kiosk / autologon lockout ----------------------------------------------
# During provisioning the junadmin account auto-logs in and runs ONLY the status
# GUI as its shell (no explorer = no desktop = locked out).  Autologon is armed
# in Bootstrap and re-armed (AutoLogonCount) on every orchestrator run so it
# survives every provisioning reboot.  Remove-KioskMode tears it all down.

$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Get-KioskUserSid {
    try { return (New-Object System.Security.Principal.NTAccount($KioskUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}

function Set-PerUserShell {
    # Sets a per-user Winlogon Shell for junadmin so ONLY junadmin gets the kiosk
    # shell - the real end-user account is never touched.  Uses the per-SID
    # "...\Winlogon\SpecialAccounts" ... no; the supported per-user mechanism is
    # HKLM\...\Winlogon\AlternateShells or the per-user GINA.  We use the documented
    # per-user custom shell via HKLM "...\Winlogon\Shell" only as a fallback.
    param([string]$ShellCommand)
    $sid = Get-KioskUserSid
    if (-not $sid) { return $false }
    # Per-user shell lives under the user's hive:
    #   HKEY_USERS\<SID>\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell
    # The hive may not be loaded when we run as SYSTEM pre-logon, so load it.
    $hivePath = "C:\Users\$KioskUser\NTUSER.DAT"
    $loaded = $false
    try {
        if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
            if (Test-Path $hivePath) {
                & reg.exe load "HKU\$sid-kiosk" $hivePath *>$null
                $sid = "$sid-kiosk"; $loaded = $true
            }
        }
        $userWinlogon = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        if (-not (Test-Path $userWinlogon)) { New-Item -Path $userWinlogon -Force | Out-Null }
        New-ItemProperty -Path $userWinlogon -Name 'Shell' -Value $ShellCommand -PropertyType String -Force | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        if ($loaded) { [gc]::Collect(); & reg.exe unload "HKU\$($sid)" *>$null }
    }
}

function Remove-PerUserShell {
    $sid = Get-KioskUserSid
    if (-not $sid) { return }
    $hivePath = "C:\Users\$KioskUser\NTUSER.DAT"
    $loaded = $false
    try {
        if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
            if (Test-Path $hivePath) {
                & reg.exe load "HKU\$sid-kiosk" $hivePath *>$null
                $sid = "$sid-kiosk"; $loaded = $true
            }
        }
        $userWinlogon = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        if (Test-Path $userWinlogon) {
            Remove-ItemProperty -Path $userWinlogon -Name 'Shell' -ErrorAction SilentlyContinue
        }
    } catch {
    } finally {
        if ($loaded) { [gc]::Collect(); & reg.exe unload "HKU\$($sid)" *>$null }
    }
}

function Set-AutoLogon {
    # Arms autologon for junadmin.  Password comes from the bootstrap API (the
    # same value 04-install-packages sets); never stored in the repo.  We set a
    # high AutoLogonCount so the kiosk survives many reboots, and re-arm it each run.
    param([string]$Password, [int]$Count = 999)
    try {
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'  -Value '1'        -Type String -Force
        Set-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName' -Value $KioskUser -Type String -Force
        Set-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String -Force
        if ($Password) {
            Set-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword' -Value $Password -Type String -Force
        }
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'  -Value $Count -Type DWord -Force
        return $true
    } catch { return $false }
}

function Reset-AutoLogonCount {
    # Re-arm the count on every boot so a long, many-reboot Windows Update run
    # never exhausts it and drops to the normal login screen mid-provision.
    param([int]$Count = 999)
    try {
        if ((Get-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon -eq '1') {
            Set-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount' -Value $Count -Type DWord -Force
        }
    } catch {}
}

function Set-KioskMode {
    # Arm autologon + kiosk shell for the provisioning lockout.
    #
    # Shell strategy: junadmin is the ONLY account that logs on during provisioning
    # (autologon), and the kiosk is fully torn down before any real user ever logs
    # in.  So we set the system-wide HKLM ...\Winlogon\Shell (reliable, honored even
    # on the very first logon when junadmin has no profile/NTUSER.DAT yet).  We ALSO
    # set the per-user shell as a belt-and-suspenders extra once the profile exists.
    # Remove-KioskMode wipes BOTH on completion, restoring explorer.exe.
    param([string]$Password)
    $shellCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SetupRoot\provision-status.ps1`""

    # Primary: system-wide Winlogon Shell.
    $okShell = $false
    try {
        Set-ItemProperty -Path $WinlogonKey -Name 'Shell' -Value $shellCmd -Type String -Force
        $okShell = $true
    } catch {}

    # Belt-and-suspenders: per-user shell (no-op if junadmin profile not created yet).
    $okPerUser = Set-PerUserShell -ShellCommand $shellCmd

    $okLogon = Set-AutoLogon -Password $Password -Count 999
    # Hide the "Switch user" / other-user tiles so nobody can sidestep the kiosk.
    try {
        $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if (-not (Test-Path $polKey)) { New-Item -Path $polKey -Force | Out-Null }
        Set-ItemProperty -Path $polKey -Name 'HideFastUserSwitching' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $polKey -Name 'dontdisplaylastusername' -Value 0 -Type DWord -Force
    } catch {}
    Write-Log "Kiosk mode armed (sysShell=$okShell perUser=$okPerUser autologon=$okLogon) for $KioskUser" -MasterOnly
}

function Remove-KioskMode {
    # Teardown: restore explorer.exe shell, clear autologon, re-enable normal logon.
    # Idempotent and safe to call even if a phase errored.
    # Restore the system-wide shell to the Windows default (explorer.exe).
    try {
        Set-ItemProperty -Path $WinlogonKey -Name 'Shell' -Value 'explorer.exe' -Type String -Force
    } catch {}
    Remove-PerUserShell
    try {
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -Value '0' -Type String -Force
        Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword'   -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'    -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'   -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -ErrorAction SilentlyContinue
    } catch {}
    try {
        $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if (Test-Path $polKey) {
            Remove-ItemProperty -Path $polKey -Name 'HideFastUserSwitching' -ErrorAction SilentlyContinue
        }
    } catch {}
    Write-Log "Kiosk mode removed - explorer shell + normal logon restored" -MasterOnly
}

# Break-glass / safety timeout.  If imaging has been running absurdly long (a
# stuck phase, a hung update), drop the kiosk so a tech isn't locked out forever.
# Tech break-glass: create the flag file C:\ProgramData\JuniperSetup\break-glass.txt
# (e.g. from another machine over the admin share, or a recovery shell) and reboot
# - the next orchestrator run tears down the kiosk and returns a normal desktop.
$KioskMaxHours = 8
function Test-BreakGlass {
    $flag = "$SetupRoot\break-glass.txt"
    if (Test-Path $flag) { return $true }
    # Auto-escape after $KioskMaxHours since imaging first started.
    $startMarker = "$SetupRoot\.imaging-start"
    try {
        if (Test-Path $startMarker) {
            $start = [datetime](Get-Content $startMarker -Raw).Trim()
            if ((New-TimeSpan -Start $start -End (Get-Date)).TotalHours -ge $KioskMaxHours) { return $true }
        } else {
            (Get-Date -Format 'o') | Set-Content $startMarker -Encoding ASCII
        }
    } catch {}
    return $false
}

function Invoke-Phase {
    param([string]$PhaseName)

    $script = Join-Path $ScriptsDir $Phases[$PhaseName]
    if (-not (Test-Path $script)) {
        Write-Log "Script missing: $script - skipping phase '$PhaseName'" -Level WARN
        return 0   # treat as success so imaging continues
    }

    $outFile = "$SetupRoot\logs\$PhaseName-raw.txt"
    $errFile = "$SetupRoot\logs\$PhaseName-err.txt"

    Write-Log "Executing: $script"

    $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`"" `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile

    # Append captured output into the phase log
    $phaseLog = "$SetupRoot\logs\$PhaseName.log"
    if (Test-Path $outFile) {
        Get-Content $outFile | Add-Content -LiteralPath $phaseLog -Encoding UTF8 -ErrorAction SilentlyContinue
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $errFile) {
        $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($errText -and $errText.Trim()) {
            Add-Content -LiteralPath $phaseLog -Value '--- STDERR ---' -Encoding UTF8 -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $phaseLog -Value $errText         -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    return $p.ExitCode
}

function Sync-Scripts {
    # Pulls fresh phase scripts from the deploy share before running each phase.
    # Allows hotfixing phase scripts without re-imaging the machine.
    # Silently skipped if the share is unreachable.
    $shareScripts = '\\192.168.5.141\deploy$\scripts'
    if (-not (Test-Path $shareScripts -ErrorAction SilentlyContinue)) { return }
    try {
        # Phase scripts go into $ScriptsDir
        foreach ($f in $Phases.Values) {
            $src = Join-Path $shareScripts $f
            $dst = Join-Path $ScriptsDir $f
            if (Test-Path $src) {
                Copy-Item $src $dst -Force -ErrorAction SilentlyContinue
            }
        }
        # provision-status.ps1: keep both the root copy (kiosk shell target) and
        # the scripts copy fresh so the lockout screen can be hotfixed too.
        $psSrc = Join-Path $shareScripts 'provision-status.ps1'
        if (Test-Path $psSrc) {
            Copy-Item $psSrc "$SetupRoot\provision-status.ps1" -Force -ErrorAction SilentlyContinue
            Copy-Item $psSrc (Join-Path $ScriptsDir 'provision-status.ps1') -Force -ErrorAction SilentlyContinue
        }
        # Logging.ps1 lives at $SetupRoot (dot-sourced directly by each phase script)
        $logSrc = Join-Path $shareScripts 'Logging.ps1'
        if (Test-Path $logSrc) {
            Copy-Item $logSrc "$SetupRoot\Logging.ps1" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    # No Write-Log here - Logging.ps1 may have just been replaced
}

# ---- Bootstrap: first call from SetupComplete.cmd ---------------------------

if ($Bootstrap) {
    Write-Log "=== Juniper Imaging Orchestrator v1.1 - $env:COMPUTERNAME ===" -MasterOnly
    Write-Log "Bootstrap started on $env:COMPUTERNAME"

    # Record imaging-start time for the kiosk safety timeout.
    if (-not (Test-Path "$SetupRoot\.imaging-start")) {
        (Get-Date -Format 'o') | Set-Content "$SetupRoot\.imaging-start" -Encoding ASCII
    }

    # Create the JuniperImaging scheduled task (fires on every startup, SYSTEM)
    $action    = New-ScheduledTaskAction `
                    -Execute 'powershell.exe' `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SetupRoot\orchestrator.ps1`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -RestartCount 0

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Juniper IT post-imaging automated setup' -Force | Out-Null

    Write-Log "Scheduled task '$TaskName' registered (AtStartup, SYSTEM)"

    # Set all network connections to Private so WinRM cross-subnet access works.
    # Without this, Windows leaves new connections as Public, which restricts
    # the WinRM firewall rule to same-subnet only.
    try {
        Get-NetConnectionProfile |
            Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' } |
            Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
        Write-Log "Network profile set to Private" -MasterOnly
    } catch {
        Write-Log "Network profile update failed (non-fatal): $_" -Level WARN -MasterOnly
    }

    # Enable WinRM so IT can reach the machine remotely during and after imaging.
    # -SkipNetworkProfileCheck allows it even when the NIC profile is Public.
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
        # Trust the imaging subnet so IT workstations can connect without extra config
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.0.*,192.168.1.*,192.168.2.*,192.168.3.*,192.168.4.*,192.168.5.*,192.168.6.*,192.168.7.*,192.168.8.*,192.168.9.*,192.168.10.*' `
            -Force -ErrorAction SilentlyContinue
        Write-Log "WinRM enabled (PSRemoting active)" -MasterOnly
    } catch {
        Write-Log "WinRM enable failed (non-fatal): $_" -Level WARN -MasterOnly
    }

    # Write initial phase state if not already present
    if (-not (Test-Path $PhaseFile)) {
        Save-PhaseState -Phase 'windows-update' -Round 0
        Write-Log "Phase state initialized: windows-update" -MasterOnly
    }

    # Seed progress.json so the status GUI has something to show on first launch.
    Write-ProgressJson -OverallPercent 2 -PhaseKey 'bootstrap' `
        -PhaseLabel 'Preparing this PC' -PhaseIndex 0 -PhaseTotal $Phases.Count `
        -StepMessage 'Starting setup' -State 'running'

    # Change junadmin password immediately so CHANGEME is not live during imaging,
    # AND arm the kiosk/autologon using that same password (never stored in repo).
    # The bootstrap API returns the same password that 04-install-packages.ps1 will set.
    try {
        $invApi   = 'http://192.168.5.141:8080'
        $resp     = Invoke-RestMethod "$invApi/api/management/bootstrap" -TimeoutSec 10 -ErrorAction Stop
        $bPass    = $resp.password
        if ($bPass) {
            $secPass = ConvertTo-SecureString $bPass -AsPlainText -Force
            Set-LocalUser -Name $KioskUser -Password $secPass -ErrorAction Stop
            Write-Log "junadmin password updated from bootstrap API" -MasterOnly
            # Arm the provisioning lockout with the live password.
            Set-KioskMode -Password $bPass
            $secPass = $null; $bPass = $null; $resp = $null
        } else {
            Write-Log "Bootstrap API returned no password - kiosk NOT armed (CHANGEME active)" -Level WARN -MasterOnly
        }
    } catch {
        Write-Log "Could not update junadmin password at bootstrap: $_ (CHANGEME still active, kiosk not armed)" -Level WARN -MasterOnly
    }

    Write-Log "Bootstrap complete - proceeding to first phase"
    # Fall through to main execution block below
}

# ---- Every run: keep the kiosk armed + check break-glass --------------------

# Re-arm the autologon count so a long multi-reboot run never falls back to the
# normal login screen mid-provision.
Reset-AutoLogonCount -Count 999

# Break-glass / safety timeout: if a tech dropped the flag file or imaging has run
# too long, tear down the kiosk so the machine isn't locked forever, then let the
# phase logic continue (it will still complete teardown normally when phases end).
if (Test-BreakGlass) {
    Write-Log "Break-glass / safety timeout triggered - removing kiosk lockout" -Level WARN -MasterOnly
    Remove-KioskMode
}

# ---- Main: run current phase ------------------------------------------------

$state = Get-PhaseState
$phase = $state.phase

if ($phase -eq 'done') {
    Write-Log "=== All imaging phases complete on $env:COMPUTERNAME ===" -MasterOnly
    Write-Log "All phases complete - tearing down kiosk + removing scheduled task"
    Write-ProgressJson -OverallPercent 100 -PhaseKey 'done' `
        -PhaseLabel 'Setup complete' -PhaseIndex $Phases.Count -PhaseTotal $Phases.Count `
        -StepMessage 'Almost finished - restarting' -State 'done'
    Remove-KioskMode
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    # Give the status GUI a moment to show "done" then reboot into a clean login.
    Start-Sleep 6
    Restart-Computer -Force
    exit 0
}

if (-not $Phases.Contains($phase)) {
    Write-Log "Unknown phase '$phase' - resetting to windows-update" -Level WARN
    $phase = 'windows-update'
}

$round = [int]($state.round) + 1
Save-PhaseState -Phase $phase -Round $round
Write-Log "--- Phase: $phase (round $round) ---" -MasterOnly
Write-Log "Starting phase '$phase' (round $round)"

# Publish progress at the START of the phase (low end of its band).
Publish-PhaseProgress -PhaseKey $phase -Fraction 0.05 -State 'running'

Sync-Scripts
$exitCode = Invoke-Phase -PhaseName $phase

Write-Log "Phase '$phase' exited: $exitCode"

if ($exitCode -eq 3010) {
    # Phase installed updates and needs a reboot - phase stays the same
    Publish-PhaseProgress -PhaseKey $phase -Fraction 0.5 -State 'rebooting'
    Write-Log "Reboot required after phase '$phase' round $round - rebooting now" -MasterOnly
    Write-Log "Rebooting in 10 seconds..."
    Start-Sleep 10
    Restart-Computer -Force

} elseif ($exitCode -eq 0) {
    # Phase complete - advance and immediately run next phase
    Publish-PhaseProgress -PhaseKey $phase -Fraction 1.0 -State 'running'
    Send-PhaseLog -PhaseKey $phase -Status 'ok'   # upload finished phase log
    $nextPhase = Get-NextPhase -Current $phase
    Write-Log "Phase '$phase' succeeded - advancing to '$nextPhase'" -MasterOnly
    Write-Log "Advancing to '$nextPhase'"
    Save-PhaseState -Phase $nextPhase -Round 0

    if ($nextPhase -eq 'done') {
        Write-Log "=== Imaging complete on $env:COMPUTERNAME - all phases succeeded ===" -MasterOnly
        Write-Log "All phases done. Tearing down kiosk + removing scheduled task."
        Write-ProgressJson -OverallPercent 100 -PhaseKey 'done' `
            -PhaseLabel 'Setup complete' -PhaseIndex $Phases.Count -PhaseTotal $Phases.Count `
            -StepMessage 'Almost finished - restarting' -State 'done'
        Remove-KioskMode
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 6
        Restart-Computer -Force
    } else {
        # Run next phase in this same session (no reboot needed)
        $round2 = 1
        Save-PhaseState -Phase $nextPhase -Round $round2
        Write-Log "--- Phase: $nextPhase (round $round2) ---" -MasterOnly
        Write-Log "Starting phase '$nextPhase' (round $round2)"
        Publish-PhaseProgress -PhaseKey $nextPhase -Fraction 0.05 -State 'running'
        Sync-Scripts
        $exitCode2 = Invoke-Phase -PhaseName $nextPhase
        Write-Log "Phase '$nextPhase' exited: $exitCode2" -MasterOnly

        if ($exitCode2 -eq 3010) {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Publish-PhaseProgress -PhaseKey $nextPhase -Fraction 0.5 -State 'rebooting'
            Write-Log "Reboot required after '$nextPhase' - rebooting, will continue at '$next2'" -MasterOnly
            Start-Sleep 10
            Restart-Computer -Force
        } elseif ($exitCode2 -eq 0) {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Publish-PhaseProgress -PhaseKey $nextPhase -Fraction 1.0 -State 'running'
            Send-PhaseLog -PhaseKey $nextPhase -Status 'ok'   # upload finished phase log
            Write-Log "Phase '$nextPhase' succeeded - next phase '$next2' will run on next scheduled trigger" -MasterOnly
            # If that was the final phase, tear down now rather than waiting for a reboot.
            if ($next2 -eq 'done') {
                Write-Log "=== Imaging complete on $env:COMPUTERNAME - all phases succeeded ===" -MasterOnly
                Write-ProgressJson -OverallPercent 100 -PhaseKey 'done' `
                    -PhaseLabel 'Setup complete' -PhaseIndex $Phases.Count -PhaseTotal $Phases.Count `
                    -StepMessage 'Almost finished - restarting' -State 'done'
                Remove-KioskMode
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep 6
                Restart-Computer -Force
            }
        } else {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Publish-PhaseProgress -PhaseKey $nextPhase -Fraction 1.0 -State 'running'
            Send-PhaseLog -PhaseKey $nextPhase -Status 'error'   # upload failed phase log
            Write-Log "Phase '$nextPhase' exited $exitCode2 (non-fatal) - continuing to '$next2'" -Level WARN -MasterOnly
        }
    }

} else {
    # Non-zero, non-3010: log the error but advance so imaging doesn't stall
    $nextPhase = Get-NextPhase -Current $phase
    Publish-PhaseProgress -PhaseKey $phase -Fraction 1.0 -State 'running'
    Send-PhaseLog -PhaseKey $phase -Status 'error'   # upload failed phase log
    Write-Log "Phase '$phase' exited $exitCode (non-fatal error) - advancing to '$nextPhase'" -Level WARN -MasterOnly
    Write-Log "Phase '$phase' non-fatal error (exit=$exitCode) - continuing" -Level WARN
    Save-PhaseState -Phase $nextPhase -Round 0
}
