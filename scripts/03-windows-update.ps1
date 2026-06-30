# 03-windows-update.ps1
# Installs all pending Windows updates using the Windows Update Agent COM API.
# Works in SYSTEM context on fresh Windows 10/11 - no module installation required.
#
# Part of the Juniper automated imaging pipeline - runs via orchestrator.ps1.
#
# Exit codes (read by orchestrator.ps1):
#   0    - no more pending updates; phase complete
#   3010 - updates were installed; reboot required to continue
#   1    - fatal error (orchestrator will log and advance anyway)
#
# GRANULAR LIVE PROGRESS:
#   The orchestrator only updates progress at phase TRANSITIONS, so during this
#   long, multi-reboot phase nothing would update.  This script therefore reports
#   its OWN progress directly + frequently via progress.ps1's Publish-Progress
#   (writes progress.json for the kiosk screen AND POSTs /ingest/deploy-progress
#   for the Imaging tab).  It reports: searching, "Found N", per-update install
#   ("Round R - installing X of Y: <Title> (<KB>)"), reboot-pending, and complete.
#   The "round" comes from phase.json so dozens of reboots read as forward motion.
#   overallPercent is kept monotonic-ish across rounds (a per-round floor) so the
#   bar never snaps backward each reboot.  All reporting is best-effort.

param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'windows-update'
Write-PhaseHeader -Description 'Windows Update'

# ---- Live progress reporting (best-effort) ----------------------------------
# progress.ps1 provides Publish-Progress (progress.json + server POST) and
# Get-ProgBandPercent (fraction-within-phase -> absolute overall percent).
# Wrapped so a missing helper never breaks imaging.
$PhaseKey   = 'windows-update'
$PhaseLabel = 'Installing Windows updates'
$PhaseIndex = 1
$PhaseTotal = 5
try { . 'C:\ProgramData\JuniperSetup\progress.ps1' } catch {}

# Round number (1-based) from the orchestrator's phase state, so progress text
# reflects the multi-reboot reality ("Round 2 ...") instead of looking like a loop.
$Round = 1
try {
    $pf = 'C:\ProgramData\JuniperSetup\phase.json'
    if (Test-Path $pf) {
        $ps = Get-Content $pf -Raw | ConvertFrom-Json
        if ($ps.round) { $Round = [int]$ps.round }
    }
} catch {}
if ($Round -lt 1) { $Round = 1 }

# Monotonic-ish band floor across rounds: each successive round starts a little
# higher in the windows-update band so the bar advances (not resets) every reboot.
# Round 1 spans fraction 0.00..~0.55 of the band; each later round bumps the floor
# (capped) so dozens of reboots keep creeping toward the band end without snapping
# back. The orchestrator owns the final 1.0 transition out of the phase.
$RoundFloor = [math]::Min(0.85, 0.10 * ($Round - 1))   # 0, .10, .20, ... cap .85
$RoundSpan  = [math]::Max(0.05, (0.92 - $RoundFloor))  # remaining headroom this round

# Report a step at a given completion fraction WITHIN this round (0..1), mapped
# into the round's slice of the windows-update band. Never throws.
function Report-WU {
    param([double]$RoundFraction = 0.0, [string]$Step = '', [string]$State = 'running')
    try {
        if (-not (Get-Command Publish-Progress -ErrorAction SilentlyContinue)) { return }
        $f = $RoundFloor + $RoundSpan * [math]::Max(0.0, [math]::Min(1.0, $RoundFraction))
        $pct = Get-ProgBandPercent -PhaseKey $PhaseKey -Fraction $f
        Publish-Progress -PhaseKey $PhaseKey -PhaseLabel $PhaseLabel `
            -OverallPercent $pct -StepMessage $Step `
            -PhaseIndex $PhaseIndex -PhaseTotal $PhaseTotal -State $State -Source 'phase-wu'
    } catch {}
}

Report-WU -RoundFraction 0.02 -Step "Round $Round - preparing Windows Update..."

# ---- Register Microsoft Update + enable driver/optional updates -------------
# Default Windows Update only delivers critical/security updates.
# Registering the Microsoft Update (MU) service adds drivers, optional updates,
# and the full hardware catalog so they appear in the WUA search results.
$muServiceId  = '7971f918-a847-4430-9279-4a52d1efe18d'
$muRegistered = $false
Write-Log 'Registering Microsoft Update service (adds driver + optional updates)...'
try {
    $muMgr = New-Object -ComObject Microsoft.Update.ServiceManager
    $muMgr.ClientApplicationID = 'Juniper Imaging'
    $muMgr.AddService2($muServiceId, 7, '') | Out-Null
    $muRegistered = $true
    Write-Log '  Microsoft Update registered'
} catch {
    Write-Log "  WARN: Microsoft Update not registered ($($_.Exception.HResult)) - Windows Update only" -Level WARN
}

# Enable driver searching and recommended updates via registry
foreach ($reg in @(
    [pscustomobject]@{
        P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
        N = 'SearchOrderConfig'; V = 1
    },
    [pscustomobject]@{
        P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        N = 'IncludeRecommendedUpdates'; V = 1
    }
)) {
    try {
        if (-not (Test-Path $reg.P)) { New-Item -Path $reg.P -Force | Out-Null }
        Set-ItemProperty -Path $reg.P -Name $reg.N -Value $reg.V -Type DWord -ErrorAction Stop
    } catch {
        Write-Log "  WARN: Could not set registry $($reg.N): $_" -Level WARN
    }
}

# ---- Clear WU download cache ------------------------------------------------
# Stale or partially-downloaded packages cause WU_E_DS_NODATA (0x80248007)
# where updates appear in the catalog but fail to install.  Clearing the
# Download folder forces a clean re-fetch on this pass.
Write-Log 'Clearing Windows Update download cache...'
try {
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $dlDir = 'C:\Windows\SoftwareDistribution\Download'
    if (Test-Path $dlDir) {
        Remove-Item "$dlDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log '  Download cache cleared'
    }
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} catch {
    Write-Log "  WARN: Could not clear WU download cache: $_" -Level WARN
    try { Start-Service wuauserv -ErrorAction SilentlyContinue } catch {}
}

# ---- Search for pending updates via COM API ---------------------------------
# Uses the built-in Windows Update Agent COM object - no PowerShellGet or module
# installation required, works natively in SYSTEM context on any Windows version.
Write-Log 'Searching for pending updates (WUA COM API)...'
Report-WU -RoundFraction 0.05 -Step "Round $Round - searching for updates..."

try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    if ($muRegistered) {
        $searcher.ServerSelection = 2   # ssOthers: use the registered Microsoft Update service
        $searcher.ServiceID       = $muServiceId
    }
    # IsInstalled=0: all pending updates (software + drivers + optional when MU is registered)
    $result   = $searcher.Search("IsInstalled=0")
} catch {
    Write-Log "Failed to create Windows Update session: $_" -Level ERROR
    Report-WU -RoundFraction 0.05 -Step 'Windows Update search failed' -State 'error'
    Write-PhaseSummary -ExitCode 1 -Notes 'WUA COM init failed'
    exit 1
}

$updates = $result.Updates
$count   = $updates.Count

if ($count -eq 0) {
    Write-Log 'No pending updates - system is current'
    Report-WU -RoundFraction 1.0 -Step 'Windows updates complete'
    Write-PhaseSummary -ExitCode 0 -Notes '0 updates pending'
    exit 0
}

Write-Log "Found $count pending update(s):"
Report-WU -RoundFraction 0.10 -Step "Round $Round - found $count update(s)"
for ($i = 0; $i -lt $count; $i++) {
    $u = $updates.Item($i)
    Write-Log "  [$($i+1)/$count] $($u.Title)" -PhaseOnly
}

if ($DryRun) {
    Write-Log "(Dry run - skipping download and install)"
    Write-PhaseSummary -ExitCode 0 -Notes "$count updates found (dry run)"
    exit 0
}

# ---- Accept EULAs -----------------------------------------------------------
for ($i = 0; $i -lt $count; $i++) {
    $u = $updates.Item($i)
    if (-not $u.EulaAccepted) {
        try { $u.AcceptEula() } catch {}
    }
}

# Short KB label for a step message: "(KB1234567)" if present, else "".
function Get-KbLabel {
    param($Update)
    try {
        if ($Update.KBArticleIDs -and $Update.KBArticleIDs.Count -gt 0) {
            return "(KB$($Update.KBArticleIDs.Item(0)))"
        }
    } catch {}
    return ''
}

# ---- Install ONE update at a time so progress is per-item -------------------
# Installing the whole collection in a single .Install() call gives no per-item
# feedback. Iterating one-at-a-time lets us report "Round R - installing X of Y:
# <Title> (<KB>)" BEFORE each item with a moving sub-percent.  WUA still handles
# downloading lazily during install, so download progress is folded in.  A reboot
# requirement on ANY item ends the round (rest install on the next reboot's round).
Write-Log "Installing $count update(s) one at a time (orchestrator handles reboot)..."
$succeeded = 0; $failed = 0; $rebootNeeded = $false; $anyAborted = $false
$rcNames = @{0='NotStarted';1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'}

for ($i = 0; $i -lt $count; $i++) {
    $u     = $updates.Item($i)
    $title = "$($u.Title)"
    $kb    = Get-KbLabel -Update $u
    $short = if ($title.Length -gt 70) { $title.Substring(0,67) + '...' } else { $title }

    # Sub-percent across the install span (0.15..0.95 of this round's slice),
    # scaled by item index so the bar creeps forward as each update completes.
    $frac = 0.15 + (0.80 * ($i / [double]$count))
    Report-WU -RoundFraction $frac -Step ("Round {0} - installing {1} of {2}: {3} {4}" -f $Round, ($i+1), $count, $short, $kb).Trim()
    Write-Log "  [$($i+1)/$count] Installing: $title $kb"

    try {
        # Single-item collection for download + install of just this update.
        $one = New-Object -ComObject Microsoft.Update.UpdateColl
        $one.Add($u) | Out-Null

        # Download this one (best-effort; some are already cached).
        try {
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $one
            $null = $dl.Download()
        } catch {
            Write-Log "       download warn: $_" -Level WARN -PhaseOnly
        }

        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $one
        $inst.AllowSourcePrompts = $false
        $ir = $inst.Install()

        $rc = [int]$ir.ResultCode
        if ($rc -eq 2) {
            $succeeded++
        } else {
            $failed++
            $hresultHex = '0x{0:X8}' -f ([int64]$ir.HResult -band 0xFFFFFFFF)
            $urName = if ($rcNames.ContainsKey($rc)) { $rcNames[$rc] } else { 'Unknown' }
            Write-Log "       FAIL code=$rc ($urName) HResult=$hresultHex" -Level WARN
            if ($rc -eq 5) { $anyAborted = $true }
        }
        if ($ir.RebootRequired) { $rebootNeeded = $true }
    } catch {
        $failed++
        Write-Log "       install exception: $_" -Level WARN
    }

    # If a reboot is pending, stop installing further items this round - they
    # will install on the next reboot's round (overallPercent floor keeps rising).
    if ($rebootNeeded) {
        Write-Log "  Reboot required after [$($i+1)/$count] - deferring remaining to next round"
        break
    }
}

Write-Log "Round $Round install summary: $succeeded succeeded, $failed failed (of $count attempted)"

if ($rebootNeeded) {
    Report-WU -RoundFraction 0.98 -Step "Round $Round - updates installed, restarting to continue..." -State 'rebooting'
    Write-Log "Updates processed ($succeeded OK, $failed failed) - reboot required"
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded installed, $failed failed, reboot required" -Reboot
    exit 3010
}

if ($anyAborted -and $succeeded -eq 0) {
    # Everything aborted with nothing installed - truly fatal, no point rebooting.
    Report-WU -RoundFraction 0.98 -Step 'Windows Update install aborted' -State 'error'
    Write-Log "Update install aborted (0/$count succeeded)" -Level ERROR
    Write-PhaseSummary -ExitCode 1 -Notes 'Install aborted'
    exit 1
}

if ($failed -gt 0) {
    # Some updates failed but no reboot was flagged - Windows Update often needs
    # multiple passes. Reboot and retry; the search next round skips installed
    # ones and retries the rest.
    Report-WU -RoundFraction 0.98 -Step "Round $Round - some updates need a retry, restarting..." -State 'rebooting'
    Write-Log "Some updates failed ($succeeded/$count succeeded) - rebooting to retry" -Level WARN
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded/$count OK, $failed failed, retrying after reboot" -Reboot
    exit 3010
}

# Installed but no reboot flag - check for chained prereqs (new updates that
# only became visible after this batch installed).
$remaining = 0
try {
    $remaining = $searcher.Search("IsInstalled=0").Updates.Count
} catch {}

if ($remaining -gt 0) {
    Report-WU -RoundFraction 0.98 -Step "Round $Round - more updates available, restarting..." -State 'rebooting'
    Write-Log "$count installed, $remaining more pending - signaling reboot to re-run"
    Write-PhaseSummary -ExitCode 3010 -Notes "$count installed, $remaining remaining" -Reboot
    exit 3010
}

Report-WU -RoundFraction 1.0 -Step 'Windows updates complete'
Write-Log "$count update(s) installed successfully"
Write-PhaseSummary -ExitCode 0 -Notes "$count updates installed"
exit 0
