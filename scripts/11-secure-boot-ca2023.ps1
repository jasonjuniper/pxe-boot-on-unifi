# 11-secure-boot-ca2023.ps1
# Secure Boot CA-2023 remediation phase - Juniper automated imaging pipeline.
# Runs LAST (after file-associations) via orchestrator.ps1.
#
# WHAT IT DOES
#   1. Ensures this machine's UEFI signature database (db) trusts the
#      "Windows UEFI CA 2023" certificate, so it will boot CA2023-signed media
#      (our PXE / WinPE boot manager). Delivered via the Microsoft servicing
#      mechanism: arm HKLM\...\SecureBoot\AvailableUpdates = 0x5944 and run the
#      \Microsoft\Windows\PI\Secure-Boot-Update task. 0x5944 is Microsoft's
#      recommended bundle - it ADDS the 2023 CA + KEK + new boot manager and does
#      NOT apply any DBX revocation, so it can never brick the current boot chain.
#      The db add needs >=2 reboots; we loop via exit 3010 (round-guarded).
#   2. Once the db trusts CA2023, re-enables Secure Boot headlessly (per-vendor).
#
# WHY POST-OS AND NOT WINPE
#   The CA2023 db update is delivered by Windows' own Secure-Boot-Update servicing
#   task + firmware variable servicing, which only run in the full OS - WinPE
#   cannot enroll the cert. Machines are PXE-imaged with Secure Boot temporarily
#   OFF; this phase makes them CA2023-trusting and flips Secure Boot back on at the
#   end of imaging.
#
# EXIT CODES (read by orchestrator.ps1)
#   0    - complete (db trusts CA2023; SB enabled OR flagged 'pending manual')
#   3010 - reboot required (mid-enrollment; orchestrator reboots + re-runs phase)
#   1    - fatal error (avoided by design; we flag + exit 0 instead of blocking)
#
# JUNIPER DECISIONS BAKED IN
#   * NO BIOS/supervisor passwords are ever set or required.
#   * Re-enabling Secure Boot often needs a one-time physical F10 confirm at the
#     firmware. When a headless enable cannot complete we FLAG the device
#     'pending manual enable' and exit 0 - we NEVER stall at a firmware prompt.
#     (One-time fix per machine, per Juniper.)
#
# USAGE: .\11-secure-boot-ca2023.ps1
#        .\11-secure-boot-ca2023.ps1 -DryRun

param([switch]$DryRun)

$ErrorActionPreference = 'SilentlyContinue'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'secure-boot'
Write-PhaseHeader -Description 'Secure Boot CA-2023 remediation'

# Append-only event timeline (best-effort); load with a safe no-op fallback so a
# missing progress.ps1 can never break this phase.
try { . 'C:\ProgramData\JuniperSetup\progress.ps1' } catch {}
if (-not (Get-Command Publish-Event -ErrorAction SilentlyContinue)) {
    function Publish-Event { param([Parameter(ValueFromRemainingArguments)]$args) }
}

$PhaseKey   = 'secure-boot'
$SetupRoot  = 'C:\ProgramData\JuniperSetup'
$InvApi     = 'http://192.168.5.141:8080'
$MaxRounds  = 6            # hard cap on reboot-enroll loops; never spin forever

# ---- Registry locations (per Microsoft KB5025885 / IT-managed servicing) -----
$SbKey             = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$SbServicing       = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$AvailUpdatesValue = 0x5944   # add CA2023 to db + KEK + new boot mgr (NO revocation)
$SbTaskPath        = '\Microsoft\Windows\PI\'
$SbTaskName        = 'Secure-Boot-Update'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-PhaseRound {
    # orchestrator.ps1 writes phase.json with the current round BEFORE calling us.
    try {
        $pj = Get-Content "$SetupRoot\phase.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($pj.phase -eq 'secure-boot' -and $pj.round) { return [int]$pj.round }
    } catch {}
    return 1
}

function Test-IsUefiSecureBootCapable {
    # $true  = UEFI + Secure Boot supported (Confirm-SecureBootUEFI returns a bool)
    # $false = legacy BIOS / SB unsupported (cmdlet throws on those platforms)
    try { Confirm-SecureBootUEFI | Out-Null; return $true } catch { return $false }
}

function Get-SecureBootEnabled {
    try { return [bool](Confirm-SecureBootUEFI) } catch { return $false }
}

function Test-DbHasCA2023 {
    # Decode the raw db UEFI variable and look for the CA2023 subject string.
    # This is the authoritative signal: as soon as the cert is in db, Secure Boot
    # will accept our CA2023-signed boot media.
    try {
        $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
        if (-not $db -or -not $db.Bytes) { return $false }
        $ascii = [System.Text.Encoding]::ASCII.GetString($db.Bytes)
        $uni   = [System.Text.Encoding]::Unicode.GetString($db.Bytes)
        return ($ascii -match 'Windows UEFI CA 2023' -or $uni -match 'Windows UEFI CA 2023')
    } catch { return $false }
}

function Get-CA2023Status {
    try { return [string](Get-ItemProperty -Path $SbServicing -Name 'UEFICA2023Status' -ErrorAction Stop).UEFICA2023Status } catch { return '' }
}

function Get-CA2023Capable {
    try { return [int](Get-ItemProperty -Path $SbServicing -Name 'WindowsUEFICA2023Capable' -ErrorAction Stop).WindowsUEFICA2023Capable } catch { return -1 }
}

function Test-CA2023Trusted {
    # db carrying the cert is authoritative; servicing flags are corroborating
    # fallbacks in case Get-SecureBootUEFI cannot read the variable.
    if (Test-DbHasCA2023)            { return $true }
    if ((Get-CA2023Status) -eq 'Updated') { return $true }
    if ((Get-CA2023Capable) -ge 2)   { return $true }
    return $false
}

function Invoke-CA2023Enrollment {
    # Arm the servicing update (if not already queued) and kick the task.
    try {
        if (-not (Test-Path $SbKey)) { New-Item -Path $SbKey -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $SbKey -Name 'AvailableUpdates' -ErrorAction SilentlyContinue).AvailableUpdates
        # Re-arm only when idle: unset/0, or settled to 0x4000 (telemetry-only).
        # If it is mid-flight (e.g. 0x4100) leave it so the engine finishes its pass.
        if ($null -eq $cur -or $cur -eq 0 -or $cur -eq 0x4000) {
            Set-ItemProperty -Path $SbKey -Name 'AvailableUpdates' -Value $AvailUpdatesValue -Type DWord -Force
            Write-Log ("Armed AvailableUpdates=0x{0:X} at {1}" -f $AvailUpdatesValue, $SbKey)
        } else {
            Write-Log ("AvailableUpdates already in progress (0x{0:X}) - not re-arming" -f $cur)
        }
    } catch { Write-Log "Failed to arm AvailableUpdates: $_" -Level WARN }

    try {
        Start-ScheduledTask -TaskPath $SbTaskPath -TaskName $SbTaskName -ErrorAction Stop
        Write-Log "Triggered $SbTaskPath$SbTaskName task"
    } catch { Write-Log "Could not start Secure-Boot-Update task: $_" -Level WARN }

    Start-Sleep -Seconds 20   # let the servicing engine process before we re-read
}

function Enable-SecureBootHeadless {
    # OS-side Secure Boot ENABLE with no BIOS password.
    # Returns: 'enabled' | 'pending-manual'
    $cs     = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $vendor = (($cs.Manufacturer) + '').Trim()
    Write-Log "Attempting headless Secure Boot enable (vendor='$vendor')"

    try {
        if ($vendor -match 'LENOVO') {
            $set  = Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosSetting   -ErrorAction Stop
            $save = Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings -ErrorAction Stop
            $r1 = $set.SetBiosSetting('SecureBoot,Enable')
            if ("$($r1.Return)" -notin 'Success','0') {
                Write-Log "Lenovo SetBiosSetting returned '$($r1.Return)'" -Level WARN
                return 'pending-manual'
            }
            $r2 = $save.SaveBiosSettings('')   # empty string = no supervisor password
            if ("$($r2.Return)" -in 'Success','0') { return 'enabled' }
            Write-Log "Lenovo SaveBiosSettings returned '$($r2.Return)'" -Level WARN
            return 'pending-manual'
        }
        elseif ($vendor -match 'Dell') {
            if (-not (Get-Module -ListAvailable -Name DellBIOSProvider)) {
                Install-Module DellBIOSProvider -Force -SkipPublisherCheck -Scope AllUsers -ErrorAction SilentlyContinue
            }
            Import-Module DellBIOSProvider -ErrorAction Stop
            Set-Item -Path 'DellSmbios:\SecureBoot\SecureBoot' -Value Enabled -ErrorAction Stop
            $now = (Get-Item 'DellSmbios:\SecureBoot\SecureBoot' -ErrorAction SilentlyContinue).CurrentValue
            if ($now -eq 'Enabled') { return 'enabled' }
            return 'pending-manual'
        }
        elseif ($vendor -match 'HP|Hewlett') {
            if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
                Install-Module HPCMSL -Force -SkipPublisherCheck -AcceptLicense -Scope AllUsers -ErrorAction SilentlyContinue
            }
            Import-Module HPCMSL -ErrorAction Stop
            # HP names the setting 'Secure Boot' (Enable/Disable) on most models, or
            # 'Configure Legacy Support and Secure Boot' on older ones. Set it, but HP
            # applies SB-enable via a next-boot physical-presence prompt that we cannot
            # satisfy headlessly, so we always report 'pending-manual' for HP - the
            # one-time F10 confirm is the accepted per-machine step.
            try { Set-HPBIOSSettingValue -Name 'Secure Boot' -Value 'Enable' -ErrorAction Stop }
            catch {
                try { Set-HPBIOSSettingValue -Name 'Configure Legacy Support and Secure Boot' `
                        -Value 'Legacy Support Disable and Secure Boot Enable' -ErrorAction Stop } catch {}
            }
            return 'pending-manual'
        }
        else {
            Write-Log "Unknown vendor '$vendor' - no headless SB-enable path" -Level WARN
            return 'pending-manual'
        }
    } catch {
        Write-Log "Headless Secure Boot enable failed: $_" -Level WARN
        return 'pending-manual'
    }
}

function Send-SbStatus {
    param([hashtable]$Payload)
    try {
        $id = @{ computer_name = $env:COMPUTERNAME }
        try { $id.serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber } catch {}
        $merged = @{}
        foreach ($k in $id.Keys)      { $merged[$k] = $id[$k] }
        foreach ($k in $Payload.Keys) { $merged[$k] = $Payload[$k] }
        $body = $merged | ConvertTo-Json -Compress
        Invoke-RestMethod "$InvApi/ingest/secure-boot-status" -Method POST -Body $body `
            -ContentType 'application/json' -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$round = Get-PhaseRound
Write-Log "Secure Boot phase starting (round $round of max $MaxRounds)"

# 0) Legacy BIOS / Secure Boot unsupported -> nothing to do.
if (-not (Test-IsUefiSecureBootCapable)) {
    Write-Log 'Machine is not UEFI Secure Boot capable (legacy BIOS or unsupported) - skipping.'
    Publish-Event -PhaseKey $PhaseKey -Step 'detect' -Status 'ok' -Message 'Not SB-capable; skipped'
    Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $false; sb_enabled = $false; action = 'skipped-legacy'; round = $round }
    Write-PhaseSummary -ExitCode 0 -Notes 'not SB-capable'
    exit 0
}

$sbEnabled    = Get-SecureBootEnabled
$trusted      = Test-CA2023Trusted
$ca2023Status = Get-CA2023Status
Write-Log "State: SecureBootOn=$sbEnabled  CA2023Trusted=$trusted  UEFICA2023Status='$ca2023Status'"

# 1) Ensure the db trusts CA2023 (reboot-loop via 3010 until it does).
if (-not $trusted) {
    if ($round -ge $MaxRounds) {
        Write-Log "CA2023 still not enrolled after $round rounds - giving up gracefully; flagging for review." -Level ERROR
        Publish-Event -PhaseKey $PhaseKey -Step 'ca2023-enroll' -Status 'error' -Message "Not enrolled after $round rounds"
        Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $false; sb_enabled = $sbEnabled; action = 'enroll-failed'; ca2023_status = $ca2023Status; round = $round }
        Write-PhaseSummary -ExitCode 0 -Notes 'CA2023 enroll gave up (max rounds)'
        exit 0   # never block the imaging pipeline
    }

    if ($DryRun) {
        Write-Log '[DryRun] Would arm AvailableUpdates=0x5944 + trigger Secure-Boot-Update, then reboot-loop until db trusts CA2023.'
        Write-PhaseSummary -ExitCode 0 -Notes '[DryRun] CA2023 enroll simulated'
        exit 0
    }

    Write-Log "db does not yet trust 'Windows UEFI CA 2023' - arming servicing + rebooting (round $round)."
    Publish-Event -PhaseKey $PhaseKey -Step 'ca2023-enroll' -Status 'running' -Message "Enrolling CA2023 (round $round)"

    Invoke-CA2023Enrollment
    $trusted = Test-CA2023Trusted   # some machines finish the db add on the first pass

    if (-not $trusted) {
        Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $false; sb_enabled = $sbEnabled; action = 'enroll-in-progress'; ca2023_status = (Get-CA2023Status); round = $round }
        Write-Log 'CA2023 servicing armed; reboot required to continue enrollment.'
        Write-PhaseSummary -ExitCode 3010 -Notes "CA2023 enroll round $round" -Reboot
        exit 3010
    }
    Write-Log 'CA2023 now trusted after arming - continuing to Secure Boot enable.'
}

Publish-Event -PhaseKey $PhaseKey -Step 'ca2023-enroll' -Status 'ok' -Message 'db trusts Windows UEFI CA 2023'

# 2) db trusts CA2023. Re-enable Secure Boot if it is currently off.
if ($sbEnabled) {
    Write-Log 'Secure Boot already ENABLED and CA2023-trusted - nothing to do.'
    Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $true; sb_enabled = $true; action = 'already-on'; ca2023_status = (Get-CA2023Status); round = $round }
    Write-PhaseSummary -ExitCode 0 -Notes 'SB already on'
    exit 0
}

Write-Log 'Secure Boot is OFF and db trusts CA2023 - attempting headless enable.'
Publish-Event -PhaseKey $PhaseKey -Step 'sb-enable' -Status 'running' -Message 'Enabling Secure Boot (headless)'
$action = if ($DryRun) { 'pending-manual' } else { Enable-SecureBootHeadless }

if ($action -eq 'enabled') {
    Write-Log 'Secure Boot enable committed at firmware - effective on next boot.'
    Publish-Event -PhaseKey $PhaseKey -Step 'sb-enable' -Status 'ok' -Message 'Secure Boot enabled'
    Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $true; sb_enabled = $false; sb_pending_reboot = $true; action = 'enabled'; round = $round }
    Write-PhaseSummary -ExitCode 0 -Notes 'SB enabled (effective next boot)'
} else {
    # pending-manual - a one-time physical F10 confirm is needed at the firmware.
    Write-Log "Secure Boot could not be enabled headlessly (action='$action') - flagged for one-time manual enable." -Level WARN
    Publish-Event -PhaseKey $PhaseKey -Step 'sb-enable' -Status 'warning' -Message 'SB pending manual enable (physical presence)'
    Send-SbStatus @{ phase = 'secure-boot'; ca2023_trusted = $true; sb_enabled = $false; sb_pending_manual = $true; action = $action; round = $round }
    Write-PhaseSummary -ExitCode 0 -Notes 'SB pending manual enable'
}

exit 0
