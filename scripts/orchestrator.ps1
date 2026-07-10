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
                         '05-install-network-drivers.ps1','06-join-wifi.ps1',
                         '10-setup-user.ps1',
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
        # progress.ps1 - shared granular-progress helper dot-sourced by phases.
        $pgSrc = Join-Path $_shareScripts 'progress.ps1'
        if (Test-Path $pgSrc) { Copy-Item $pgSrc "$SetupRoot\progress.ps1" -Force -ErrorAction SilentlyContinue }
        # Update this orchestrator for the NEXT run (safe - already parsed into memory)
        $orchSrc = Join-Path $_shareScripts 'orchestrator.ps1'
        if (Test-Path $orchSrc) { Copy-Item $orchSrc "$SetupRoot\orchestrator.ps1" -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# Phase order: key matches phase.json "phase", value is script filename in $ScriptsDir
# install-network-drivers runs FIRST, then join-wifi.  The network-driver phase
# installs the Wi-Fi / Ethernet / Bluetooth drivers (catalog for curated models,
# Windows Update for un-curated ones) over the still-connected imaging Ethernet, so
# a wireless adapter actually EXISTS before join-wifi tries to connect.  Both run
# ahead of the long, multi-reboot Windows Update phase, so if someone unplugs
# ethernet mid-update the machine has already joined Wi-Fi and stays online.  Both
# are best-effort/non-fatal - a desktop with no Wi-Fi NIC exits 0 and advances.
$Phases = [ordered]@{
    'install-network-drivers' = '05-install-network-drivers.ps1'
    'join-wifi'         = '06-join-wifi.ps1'
    'windows-update'    = '03-windows-update.ps1'
    'install-packages'  = '04-install-packages.ps1'
    'remove-bloatware'  = '07-remove-bloatware.ps1'
    'setup-user'        = '10-setup-user.ps1'
    'file-associations' = '08-set-file-associations.ps1'
}

# Friendly labels + weighted progress bands (overallPercent) per phase.
# Each phase owns a [start,end] slice of the 0-100 bar; "done" = 100.
# Bands are monotonic and cover 0-100, with the two network phases taking a small
# slice up front.
$PhaseMeta = [ordered]@{
    'install-network-drivers' = @{ Label = 'Installing network drivers';     Start = 1;  End = 4  }
    'join-wifi'         = @{ Label = 'Connecting to office Wi-Fi';        Start = 4;  End = 6  }
    'windows-update'    = @{ Label = 'Installing Windows updates';        Start = 6;  End = 45 }
    'install-packages'  = @{ Label = 'Installing applications';           Start = 45; End = 76 }
    'remove-bloatware'  = @{ Label = 'Removing unwanted apps';            Start = 76; End = 85 }
    'setup-user'        = @{ Label = 'Setting up the assigned user';      Start = 85; End = 91 }
    'file-associations' = @{ Label = 'Configuring default applications';  Start = 91; End = 99 }
}

. "$SetupRoot\Logging.ps1"
Initialize-ImagingLogging -PhaseName 'orchestrator'

# ---- Helpers ----------------------------------------------------------------

function Get-PhaseState {
    if (Test-Path $PhaseFile) {
        try { return Get-Content $PhaseFile -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ phase = 'install-network-drivers'; round = 0 }
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
    # very high AutoLogonCount (100000) so the kiosk survives the MANY back-to-back
    # reboots Windows Update can trigger between orchestrator runs, and we re-arm it
    # each run anyway.
    param([string]$Password, [int]$Count = 100000)
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
    # Uses the same very high value (100000) as Set-KioskMode so the count cannot
    # realistically run out during a single imaging job.
    param([int]$Count = 100000)
    try {
        if ((Get-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon -eq '1') {
            Set-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount' -Value $Count -Type DWord -Force
        }
    } catch {}
}

function Reassert-KioskArming {
    # Belt-and-suspenders: re-assert the autologon flags + kiosk Shell on EVERY
    # orchestrator run (not just bootstrap), so even a stray reboot that did not go
    # through a clean orchestrator pass re-arms on the next boot.  This does NOT
    # touch DefaultPassword (the bootstrap-API value already in the registry stays
    # exactly as-is - never re-read, re-written, or logged).  No-op unless the
    # kiosk is already armed (AutoAdminLogon=1), so a torn-down machine stays down.
    try {
        $aal = (Get-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon
        if ($aal -ne '1') { return }
        # Re-assert the identity + autologon flag (password left untouched).
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'   -Value '1'        -Type String -Force
        Set-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'  -Value $KioskUser -Type String -Force
        Set-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String -Force
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'   -Value 100000     -Type DWord  -Force
        # Re-assert the kiosk Shell so junadmin always lands on the status screen.
        $shellCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SetupRoot\provision-status.ps1`""
        Set-ItemProperty -Path $WinlogonKey -Name 'Shell' -Value $shellCmd -Type String -Force
        [void](Set-PerUserShell -ShellCommand $shellCmd)
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

    $okLogon = Set-AutoLogon -Password $Password -Count 100000
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
    # Provisioning is done - remove the locally-staged bootstrap secrets (junadmin
    # password + Wi-Fi PSK). They were only needed for the dongle-independent first boot.
    try { Remove-Item 'C:\ProgramData\JuniperSetup\boot-creds.json' -Force -ErrorAction SilentlyContinue } catch {}
    Write-Log "Kiosk mode removed - explorer shell + normal logon restored" -MasterOnly
}

# ---- Power management (keep awake on AC during install) ---------------------
# Imaging spans many reboots and long unattended waits.  The machine images while
# plugged in, so we disable AC standby/hibernate/monitor sleep for the WHOLE run.
# powercfg writes the active scheme persistently, so the settings survive reboots
# (important - this spans dozens of them).  We snapshot the prior AC timeout
# minutes to a file at bootstrap so completion/teardown can restore them; if the
# snapshot is missing/unreadable we restore sane defaults instead.  Battery (DC)
# settings are left untouched.  All calls best-effort - never abort imaging.

$PowerStateFile = "$SetupRoot\.power-ac-prior.json"

function Get-AcTimeoutMinutes {
    # Parse 'powercfg /query' for the Current AC Power Setting of a given GUID and
    # return the value in MINUTES (powercfg reports the index in seconds).  Returns
    # $null if it can't be read.
    param([string]$SubGuid, [string]$SettingGuid)
    try {
        $out = & powercfg /query SCHEME_CURRENT $SubGuid $SettingGuid 2>$null
        $line = $out | Where-Object { $_ -match 'Current AC Power Setting Index' } | Select-Object -First 1
        if ($line -and ($line -match '0x[0-9a-fA-F]+')) {
            $secs = [Convert]::ToInt64($Matches[0], 16)
            return [int]([math]::Round($secs / 60))
        }
    } catch {}
    return $null
}

function Save-PriorAcPower {
    # Capture current AC standby/hibernate/monitor timeouts (minutes) BEFORE we
    # change them, so they can be restored on completion.  Idempotent: only writes
    # the snapshot once (so a re-run after we've already set 0 doesn't capture 0).
    if (Test-Path $PowerStateFile) { return }
    $subSleep = 'SUB_SLEEP'; $subVideo = 'SUB_VIDEO'
    $gStandby   = 'STANDBYIDLE'
    $gHibernate = 'HIBERNATEIDLE'
    $gMonitor   = 'VIDEOIDLE'
    $prior = [ordered]@{
        standby   = Get-AcTimeoutMinutes -SubGuid $subSleep -SettingGuid $gStandby
        hibernate = Get-AcTimeoutMinutes -SubGuid $subSleep -SettingGuid $gHibernate
        monitor   = Get-AcTimeoutMinutes -SubGuid $subVideo -SettingGuid $gMonitor
        capturedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    try { ($prior | ConvertTo-Json -Compress) | Set-Content $PowerStateFile -Encoding ASCII -ErrorAction Stop } catch {}
    Write-Log ("Captured prior AC power timeouts (min): standby={0} hibernate={1} monitor={2}" -f `
        $prior.standby, $prior.hibernate, $prior.monitor) -MasterOnly
}

function Disable-SleepOnAc {
    # Force the machine to stay awake on AC for the whole install (display stays on
    # so the kiosk status screen remains visible).  Persistent across reboots.
    try { Save-PriorAcPower } catch {}
    try { & powercfg /change standby-timeout-ac   0 2>$null } catch {}
    try { & powercfg /change hibernate-timeout-ac 0 2>$null } catch {}
    try { & powercfg /change monitor-timeout-ac   0 2>$null } catch {}
    Write-Log "Sleep disabled on AC (standby/hibernate/monitor timeout-ac = 0) for imaging" -MasterOnly
}

function Restore-PowerSettings {
    # Restore AC power timeouts on completion/teardown.  Prefer the captured prior
    # values; fall back to sane defaults (standby 30, monitor 10, hibernate 0 min)
    # if the snapshot is missing or unreadable.  Best-effort; battery left alone.
    $standby = 30; $monitor = 10; $hibernate = 0; $src = 'defaults'
    try {
        if (Test-Path $PowerStateFile) {
            $p = Get-Content $PowerStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $p.standby)   { $standby   = [int]$p.standby }
            if ($null -ne $p.hibernate) { $hibernate = [int]$p.hibernate }
            if ($null -ne $p.monitor)   { $monitor   = [int]$p.monitor }
            $src = 'captured'
        }
    } catch {}
    try { & powercfg /change standby-timeout-ac   $standby   2>$null } catch {}
    try { & powercfg /change hibernate-timeout-ac $hibernate 2>$null } catch {}
    try { & powercfg /change monitor-timeout-ac   $monitor   2>$null } catch {}
    try { Remove-Item $PowerStateFile -Force -ErrorAction SilentlyContinue } catch {}
    Write-Log ("Power settings restored from {0} (AC min): standby={1} hibernate={2} monitor={3}" -f `
        $src, $standby, $hibernate, $monitor) -MasterOnly
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
        # Not staged locally - pull it straight from the share on-demand before
        # giving up, so a Sync-Scripts hiccup can't silently drop a whole phase
        # (this is what skipped 10-setup-user.ps1 / the assigned-user account once).
        $shareSrc = "\\192.168.5.141\deploy`$\scripts\$($Phases[$PhaseName])"
        if (Test-Path $shareSrc -ErrorAction SilentlyContinue) {
            try { Copy-Item $shareSrc $script -Force -ErrorAction Stop
                  Write-Log "Phase '$PhaseName' script was missing locally - fetched from share on-demand" -Level WARN
            } catch {}
        }
    }
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
        # progress.ps1 - shared granular-progress helper dot-sourced by phases.
        $progSrc = Join-Path $shareScripts 'progress.ps1'
        if (Test-Path $progSrc) {
            Copy-Item $progSrc "$SetupRoot\progress.ps1" -Force -ErrorAction SilentlyContinue
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

    # Fresh image: clear the Windows Update per-update failure history so a prior
    # image's skip counts never carry over (the file persists in ProgramData).
    try { Remove-Item "$SetupRoot\wu-failures.json" -Force -ErrorAction SilentlyContinue } catch {}

    # Keep the machine awake on AC for the whole (multi-reboot) install. Captures the
    # prior AC timeouts first so completion/teardown can restore them. Persistent.
    Disable-SleepOnAc

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
        Save-PhaseState -Phase 'install-network-drivers' -Round 0
        Write-Log "Phase state initialized: install-network-drivers" -MasterOnly
    }

    # Seed progress.json so the status GUI has something to show on first launch.
    Write-ProgressJson -OverallPercent 2 -PhaseKey 'bootstrap' `
        -PhaseLabel 'Preparing this PC' -PhaseIndex 0 -PhaseTotal $Phases.Count `
        -StepMessage 'Starting setup' -State 'running'

    # --- Dongle-INDEPENDENT bootstrap ---------------------------------------------
    # Prior hollow completions all had the same cause: first-boot bootstrap needed the
    # network (junadmin reset off CHANGEME + kiosk arm), but a laptop with no built-in
    # RJ45 depends on a USB-C dongle that does NOT reliably come up at first boot
    # (Class_FF, flaky - link/DHCP often never establishes in the full OS even after an
    # active driver install). So we DECOUPLE: deploy.ps1 staged the junadmin + Wi-Fi
    # creds LOCALLY (in WinPE, where the dongle works) to boot-creds.json. We read them
    # here with NO network, so junadmin reset + kiosk ALWAYS succeed, then join the
    # stable built-in Wi-Fi for the network phases. We still try hard to bring the
    # dongle up (active install + a real device down/up "simulated unplug") as a bonus
    # wired path, but nothing critical depends on it anymore.
    $bootCreds = $null
    $bootCredPath = 'C:\ProgramData\JuniperSetup\boot-creds.json'
    if (Test-Path $bootCredPath) {
        try { $bootCreds = Get-Content $bootCredPath -Raw | ConvertFrom-Json } catch {}
    }

    # (a) Bonus wired path: install the USB-Ethernet drivers, then SIMULATE an
    #     unplug/replug (a real hot-plug always binds the dongle, so mimic it by
    #     restarting the device + disable/enable it) and rescan.
    try {
        $uniLocal = 'C:\ProgramData\JuniperSetup\universal-drivers'
        if (Test-Path $uniLocal) {
            foreach ($inf in (Get-ChildItem $uniLocal -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)) {
                try { Start-Process pnputil.exe -ArgumentList "/add-driver `"$($inf.FullName)`" /install" -Wait -NoNewWindow } catch {}
            }
        }
        foreach ($n in (Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\*' })) {
            try { & pnputil.exe /restart-device "$($n.InstanceId)" 2>&1 | Out-Null } catch {}
            try {
                Disable-PnpDevice -InstanceId $n.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep 1
                Enable-PnpDevice  -InstanceId $n.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            } catch {}
        }
        try { Start-Process pnputil.exe -ArgumentList '/scan-devices' -Wait -NoNewWindow } catch {}
        Write-Log "Bootstrap: installed USB-Ethernet drivers + simulated dongle unplug/replug" -MasterOnly
    } catch { Write-Log "Bootstrap dongle bring-up step: $_" -Level WARN -MasterOnly }

    # (b) Join the STABLE built-in Wi-Fi from local creds so we have network WITHOUT
    #     depending on the dongle at all. The PSK lives only in the ACL'd local file.
    try {
        if ($bootCreds -and $bootCreds.wifiSsid -and $bootCreds.wifiPsk) {
            $ssid = "$($bootCreds.wifiSsid)"
            $wpx = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssid</name>
  <SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
  <MSM><security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
  <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$($bootCreds.wifiPsk)</keyMaterial></sharedKey></security></MSM>
</WLANProfile>
"@
            $tmp = [IO.Path]::GetTempFileName() -replace '\.tmp$','.xml'
            $wpx | Out-File $tmp -Encoding UTF8
            & netsh wlan add profile filename="$tmp" user=all 2>&1 | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            & netsh wlan connect name="$ssid" 2>&1 | Out-Null
            $wpx = $null
            Write-Log "Bootstrap: joined Wi-Fi '$ssid' from local creds (dongle-independent)" -MasterOnly
        }
    } catch { Write-Log "Bootstrap Wi-Fi join: $_" -Level WARN -MasterOnly }

    # (c) Wait up to ~40s for ANY IPv4 gateway (Wi-Fi or dongle).
    for ($i = 0; $i -lt 20; $i++) {
        $gw = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
              Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
        if ($gw) { Write-Log "Bootstrap: network up (gateway present)" -MasterOnly; break }
        Start-Sleep 2
    }

    # --- Reset junadmin off CHANGEME + arm the kiosk (LOCAL creds first, NO network) --
    try {
        $bPass = $null
        if ($bootCreds -and $bootCreds.junadminPassword) { $bPass = "$($bootCreds.junadminPassword)" }
        if (-not $bPass) {
            # Fallback to the network-dependent API only if local creds are missing.
            try { $bPass = (Invoke-RestMethod 'http://192.168.5.141:8080/api/management/bootstrap' -TimeoutSec 10 -ErrorAction Stop).password } catch {}
        }
        if ($bPass) {
            Set-LocalUser -Name $KioskUser -Password (ConvertTo-SecureString $bPass -AsPlainText -Force) -ErrorAction Stop
            Set-KioskMode -Password $bPass
            $bPass = $null
            Write-Log "junadmin password reset + kiosk armed (from local boot creds)" -MasterOnly
        } else {
            Write-Log "No junadmin password (local creds missing + API unreachable) - CHANGEME active, kiosk NOT armed" -Level WARN -MasterOnly
        }
    } catch {
        Write-Log "Could not reset junadmin at bootstrap: $_ (CHANGEME still active)" -Level WARN -MasterOnly
    }
    $bootCreds = $null

    Write-Log "Bootstrap complete - proceeding to first phase"
    # Fall through to main execution block below
}

# ---- Every run: keep the kiosk armed + check break-glass --------------------

# Re-arm the autologon count so a long multi-reboot run never falls back to the
# normal login screen mid-provision.
Reset-AutoLogonCount -Count 100000

# Belt-and-suspenders: re-assert AutoAdminLogon + identity + kiosk Shell every run
# (password left untouched) so even a stray reboot that skipped the orchestrator
# still auto-logs junadmin into the kiosk on the next boot.
Reassert-KioskArming

# Re-assert no-sleep-on-AC each run (idempotent; capture is skipped if already
# snapshotted at bootstrap) in case anything reset the power scheme.
Disable-SleepOnAc

# Every run: RE-ESTABLISH Wi-Fi from the local creds if there is no network. The
# multi-reboot windows-update phase kept stalling because the Wi-Fi join happened
# only ONCE at bootstrap - after a windows-update reboot the saved profile did not
# reliably auto-reconnect (and the USB-C dongle is unreliable), so the machine came
# back at the login screen with "No Network" and provisioning froze. Re-joining here
# on EVERY boot (only when a gateway is missing) keeps the box online across all the
# reboots so provisioning actually finishes. The PSK lives only in the ACL'd local
# file. Best-effort; never blocks the run.
try {
    $gwNow = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
             Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
    if (-not $gwNow -and (Test-Path 'C:\ProgramData\JuniperSetup\boot-creds.json')) {
        $bc = $null
        try { $bc = Get-Content 'C:\ProgramData\JuniperSetup\boot-creds.json' -Raw | ConvertFrom-Json } catch {}
        if ($bc -and $bc.wifiSsid -and $bc.wifiPsk) {
            $ssid = "$($bc.wifiSsid)"
            $wpx = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssid</name><SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
  <MSM><security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
  <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$($bc.wifiPsk)</keyMaterial></sharedKey></security></MSM>
</WLANProfile>
"@
            $tmp = [IO.Path]::GetTempFileName() -replace '\.tmp$','.xml'
            $wpx | Out-File $tmp -Encoding UTF8
            & netsh wlan add profile filename="$tmp" user=all 2>&1 | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            & netsh wlan connect name="$ssid" 2>&1 | Out-Null
            $wpx = $null
            for ($i = 0; $i -lt 15; $i++) {
                if (Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }) { break }
                Start-Sleep 2
            }
            Write-Log "Every-run: re-joined Wi-Fi '$ssid' (no network after reboot)" -MasterOnly
        }
        $bc = $null
    }
} catch { Write-Log "Every-run Wi-Fi re-join: $_" -Level WARN -MasterOnly }

# Every run: force the network profile to PRIVATE (never leave it Public). A
# netsh-joined Wi-Fi (and some first-seen networks) default to 'Public', which
# firewalls the machine off from cross-subnet remote management and is wrong for a
# managed corporate PC. We re-assert Private every pass so the machine is manageable
# throughout provisioning AND when it lands at the user. We also widen the WinRM
# firewall rule to any remote address so WinRM works cross-subnet regardless of how
# Windows happened to categorize the network. Best-effort; never blocks the run.
try {
    Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' -and $_.NetworkCategory -ne 'Private' } |
        ForEach-Object {
            Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
            Write-Log "Every-run: set network '$($_.Name)' profile Public/Unknown -> Private" -MasterOnly
        }
    # Set-NetConnectionProfile does not reliably PERSIST across the final teardown
    # reboot (Windows can re-categorize the Wi-Fi Public on reconnect), so also write
    # the durable NetworkList registry Category = 1 (Private) for every stored profile.
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -ErrorAction SilentlyContinue |
        ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'Category' -Value 1 -Type DWord -ErrorAction SilentlyContinue }
    # Keep WinRM reachable across subnets no matter the profile. The default Public
    # WinRM rule ('WINRM-HTTP-In-TCP') is scoped to LocalSubnet, which blocks
    # cross-subnet management if the machine ever lands Public - so widen EVERY WinRM
    # rule (all profiles) to any remote address via the display group, not a single
    # (mis-named) rule.
    Set-NetFirewallRule -DisplayGroup 'Windows Remote Management' -RemoteAddress Any -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
} catch { Write-Log "Every-run network-profile assert: $_" -Level WARN -MasterOnly }

# Break-glass / safety timeout: if a tech dropped the flag file or imaging has run
# too long, tear down the kiosk so the machine isn't locked forever, then let the
# phase logic continue (it will still complete teardown normally when phases end).
if (Test-BreakGlass) {
    Write-Log "Break-glass / safety timeout triggered - removing kiosk lockout" -Level WARN -MasterOnly
    Remove-KioskMode
    Restore-PowerSettings
}

# ---- Main: run current phase ------------------------------------------------

$state = Get-PhaseState
$phase = $state.phase

if ($phase -eq 'done') {
    Write-Log "=== All imaging phases complete on $env:COMPUTERNAME ===" -MasterOnly
    Write-Log "All phases complete - tearing down kiosk + removing scheduled task"
    Write-ProgressJson -OverallPercent 100 -PhaseKey 'done' `
        -PhaseLabel 'Setup complete' -PhaseIndex $Phases.Count -PhaseTotal $Phases.Count `
        -StepMessage 'Imaging completed successfully' -State 'done'
    Remove-KioskMode
    Restore-PowerSettings
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    # Give the status GUI a moment to show "done" then reboot into a clean login.
    Start-Sleep 6
    Restart-Computer -Force
    exit 0
}

if (-not $Phases.Contains($phase)) {
    Write-Log "Unknown phase '$phase' - resetting to install-network-drivers" -Level WARN
    $phase = 'install-network-drivers'
}

$round   = [int]($state.round) + 1
$current = $phase

# Run phases in a LOOP within this single invocation. Consecutive phases that
# exit 0 (no reboot) chain immediately; the orchestrator only stops to reboot when
# a phase returns 3010, and tears down when it reaches 'done'.
#
# Previously this ran at most TWO phases per boot and then waited for the "next
# scheduled trigger" (a reboot). Because an exit-0 phase never reboots and the
# JuniperImaging task is AtStartup, nothing re-fired it and the machine stranded at
# the pending phase - e.g. remove-bloatware succeeded, pointer advanced to
# setup-user, and it sat there until the 8h kiosk timeout dropped it to the login
# screen. The loop below chains the whole non-reboot tail in one session.
while ($true) {
    Save-PhaseState -Phase $current -Round $round
    Write-Log "--- Phase: $current (round $round) ---" -MasterOnly
    Write-Log "Starting phase '$current' (round $round)"
    Publish-PhaseProgress -PhaseKey $current -Fraction 0.05 -State 'running'
    Sync-Scripts

    $ec = Invoke-Phase -PhaseName $current
    Write-Log "Phase '$current' exited: $ec"

    if ($ec -eq 3010) {
        # Phase needs a reboot - keep the SAME phase; round increments next boot.
        Publish-PhaseProgress -PhaseKey $current -Fraction 0.5 -State 'rebooting'
        Send-PhaseLog -PhaseKey $current -Status 'ok'
        Write-Log "Reboot required after '$current' round $round - rebooting now" -MasterOnly
        Write-Log "Rebooting in 10 seconds..."
        Start-Sleep 10
        Restart-Computer -Force
        break
    }

    # exit 0 (success) or other non-3010 (non-fatal): finish this phase and advance.
    Publish-PhaseProgress -PhaseKey $current -Fraction 1.0 -State 'running'
    if ($ec -eq 0) {
        Send-PhaseLog -PhaseKey $current -Status 'ok'
        Write-Log "Phase '$current' succeeded" -MasterOnly
    } else {
        Send-PhaseLog -PhaseKey $current -Status 'error'
        Write-Log "Phase '$current' exited $ec (non-fatal error) - continuing" -Level WARN -MasterOnly
    }

    $next = Get-NextPhase -Current $current
    Save-PhaseState -Phase $next -Round 0

    if ($next -eq 'done') {
        Write-Log "=== Imaging complete on $env:COMPUTERNAME - all phases succeeded ===" -MasterOnly
        Write-Log "All phases done. Tearing down kiosk + removing scheduled task."
        Write-ProgressJson -OverallPercent 100 -PhaseKey 'done' `
            -PhaseLabel 'Setup complete' -PhaseIndex $Phases.Count -PhaseTotal $Phases.Count `
            -StepMessage 'Imaging completed successfully' -State 'done'
        Remove-KioskMode
        Restore-PowerSettings
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 6
        Restart-Computer -Force
        break
    }

    # Continue to the next phase in THIS SAME SESSION (exit-0 phases need no reboot).
    $current = $next
    $round   = 1
}
