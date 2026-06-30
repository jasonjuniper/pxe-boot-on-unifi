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
$PhaseIndex = 2   # join-wifi is now phase 1; windows-update is phase 2
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

# ---- Failure tracking + loop guard ------------------------------------------
# A single update that fails every round would otherwise reboot-loop the machine
# forever (exit 3010 each round -> reboot -> same failure -> 3010 ...).  We track
# per-update fail counts across rounds in wu-failures.json and, once an update has
# failed >= $MaxFailPerUpdate rounds, SKIP it (exclude from the install set) so the
# phase can finish the other updates and reach 'done'.  We also cap total rounds
# ($MaxRounds) and stop rebooting when a round installs 0 new updates with only
# failing/skipped ones left ("stall").  In all those cases imaging COMPLETES with a
# clearly-flagged warning instead of looping.  ASCII-safe, idempotent.
$MaxFailPerUpdate = 3      # skip an update after it has failed this many rounds
$MaxRounds        = 12     # absolute backstop on Windows Update rounds
$FailFile         = 'C:\ProgramData\JuniperSetup\wu-failures.json'

# Load the persisted { "<id>": { kb=..., title=..., hresult=..., count=N } } map.
function Get-WuFailures {
    try {
        if (Test-Path $FailFile) {
            $raw = Get-Content $FailFile -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                $o = $raw | ConvertFrom-Json
                $h = @{}
                foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
                return $h
            }
        }
    } catch {}
    return @{}
}

# Persist the fail map atomically (.tmp + move). Best-effort.
function Save-WuFailures {
    param([hashtable]$Map)
    try {
        $json = ($Map | ConvertTo-Json -Depth 5 -Compress)
        $tmp  = "$FailFile.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item $tmp $FailFile -Force -ErrorAction Stop
    } catch {}
}

# Stable per-update key: prefer the WUA UpdateID (GUID), else the KB, else title.
function Get-UpdateKey {
    param($Update)
    try { if ($Update.Identity -and $Update.Identity.UpdateID) { return "$($Update.Identity.UpdateID)" } } catch {}
    try { if ($Update.KBArticleIDs -and $Update.KBArticleIDs.Count -gt 0) { return "KB$($Update.KBArticleIDs.Item(0))" } } catch {}
    return "$($Update.Title)"
}

# Bare KB label ("KB1234567" or "") for messages/summaries.
function Get-KbBare {
    param($Update)
    try { if ($Update.KBArticleIDs -and $Update.KBArticleIDs.Count -gt 0) { return "KB$($Update.KBArticleIDs.Item(0))" } } catch {}
    return ''
}

# Is this WUA update a Servicing Stack Update (SSU)?  SSUs must be installed
# BEFORE the cumulative/.NET/optional updates that depend on them - a missing or
# out-of-date servicing stack is a common cause of a cumulative/.NET update that
# fails to install every round.  We detect an SSU two ways (either is sufficient):
#   1. Categories includes the "Servicing Stack Updates" category
#      (CategoryID 2eb0c6a8-b6e9-4c33-8c39-92e9b3bf91e9), or
#   2. Title matches "Servicing Stack Update" / "*servicing stack*".
# Best-effort and wrapped - a provider quirk never throws.
$Script:SsuCategoryId = '2eb0c6a8-b6e9-4c33-8c39-92e9b3bf91e9'
function Test-IsSsu {
    param($Update)
    try {
        if ($Update.Categories) {
            foreach ($c in $Update.Categories) {
                try { if ("$($c.CategoryID)" -eq $Script:SsuCategoryId) { return $true } } catch {}
                try { if ("$($c.Name)" -match 'Servicing Stack') { return $true } } catch {}
            }
        }
    } catch {}
    try { if ("$($Update.Title)" -match 'Servicing Stack Update' -or "$($Update.Title)" -match 'servicing stack') { return $true } } catch {}
    return $false
}

# Build a failure summary string (KB + HResult per persistently-failed update).
# Defined early so the SSU-first pass (above the main install loop) can call it on
# an SSU failure; reads the script-level $failMap which exists by the time it runs.
function Get-FailureSummary {
    $lines = @()
    foreach ($k in $failMap.Keys) {
        $e = $failMap[$k]
        $kbT = if ($e.kb) { $e.kb } else { $k }
        $lines += ("{0} failed {1}x (HResult {2})" -f $kbT, $e.count, $e.hresult)
    }
    return ($lines -join '; ')
}

# Best-effort upload of the WU phase log + a concise failure summary to the
# inventory server (/ingest/deploy-log).  status='error' so the Imaging tab flags
# the card red and a tech can read which KBs failed + HResults from /deploy/status
# WITHOUT reaching the machine.  Mirrors orchestrator.ps1 Send-PhaseLog (serial ->
# mac -> hostname resolve via Get-ProgIdentity).  Never throws.
function Send-WuFailureLog {
    param([string]$Summary = '', [string]$Status = 'error')
    try {
        $invApi  = $Script:ProgInvApi; if (-not $invApi) { $invApi = 'http://192.168.5.141:8080' }
        $logPath = 'C:\ProgramData\JuniperSetup\logs\windows-update.log'
        $logText = ''
        if (Test-Path $logPath) {
            $bytes = [IO.File]::ReadAllBytes($logPath)
            $cap   = 480 * 1024
            if ($bytes.Length -gt $cap) {
                $tail    = $bytes[($bytes.Length - $cap)..($bytes.Length - 1)]
                $logText = "...[truncated to last 480 KB]...`r`n" + [Text.Encoding]::UTF8.GetString($tail)
            } else {
                $logText = [Text.Encoding]::UTF8.GetString($bytes)
            }
        }
        if ($Summary) { $logText = "===== WINDOWS UPDATE FAILURE SUMMARY =====`r`n$Summary`r`n==========================================`r`n`r`n" + $logText }
        $id = $null
        try { if (Get-Command Get-ProgIdentity -ErrorAction SilentlyContinue) { $id = Get-ProgIdentity } } catch {}
        $body = @{
            serial    = if ($id) { $id.serial }   else { $null }
            hostname  = if ($id) { $id.hostname } else { $env:COMPUTERNAME }
            mac       = if ($id) { $id.mac }      else { $null }
            phase_key = 'windows-update'
            status    = $Status
            log_text  = $logText
            ts        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$invApi/ingest/deploy-log" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 8 -ErrorAction Stop | Out-Null
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

# ---- Load persisted per-update failure history ------------------------------
# { "<updateKey>": { kb, title, hresult, count } } - count = rounds this update
# has failed.  Used to (a) skip updates that have failed >= $MaxFailPerUpdate
# rounds and (b) build the at-phase-end failure summary.
$failMap = Get-WuFailures

# ---- SSU-FIRST PASS ----------------------------------------------------------
# Servicing Stack Updates (SSUs) are a prerequisite for the cumulative/.NET/
# optional updates of the same month.  If a cumulative or .NET update is installed
# before its required SSU, it can fail to install EVERY round (a common cause of a
# repeatedly-failing update with a .NET/prerequisite flavour).  So before the main
# install flow we install ONLY the pending SSUs first, in their own pass.  SSUs
# normally do NOT need a reboot; but if the SSU install reports reboot-required we
# return 3010 so the orchestrator reboots and the NEXT round continues with the
# remaining (now-installable) updates.  This is purely an ORDERING change:
#   - No SSU pending  -> this whole block is a no-op and behaviour is exactly as before.
#   - SSUs pending    -> they install first; the main loop below then skips them
#                        (already installed -> no longer in the IsInstalled=0 set on
#                        the next round) and proceeds with everything else.
# All the existing logic (granular reporting, per-update result, skip-after-3,
# stall/round-cap, WU-log-on-failure, failMap increments) is preserved unchanged.
$ssuItems = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $count; $i++) {
    $u = $updates.Item($i)
    if (-not (Test-IsSsu -Update $u)) { continue }
    $key = Get-UpdateKey -Update $u
    $fc  = 0
    if ($failMap.ContainsKey($key)) { try { $fc = [int]$failMap[$key].count } catch { $fc = 0 } }
    # Honour the same skip-after-N guard: a persistently-failing SSU must not loop.
    if ($fc -ge $MaxFailPerUpdate) {
        Write-Log "  SSU $((Get-KbBare -Update $u)) failed ${fc}x previously - leaving to skip logic" -Level WARN
        continue
    }
    [void]$ssuItems.Add([pscustomobject]@{ Update = $u; Key = $key; Kb = (Get-KbBare -Update $u) })
}

if ($ssuItems.Count -gt 0) {
    Write-Log "SSU-first pass: $($ssuItems.Count) servicing stack update(s) pending - installing before all others"
    Report-WU -RoundFraction 0.11 -Step ("Installing servicing stack update(s) first...")
    $ssuFailedThisRound = @{}
    $ssuReboot = $false; $ssuOk = 0; $ssuFail = 0
    $ssuRcNames = @{0='NotStarted';1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'}
    for ($si = 0; $si -lt $ssuItems.Count; $si++) {
        $sItem  = $ssuItems[$si]
        $su     = $sItem.Update
        $sTitle = "$($su.Title)"
        $sKey   = $sItem.Key
        $sKbBare = $sItem.Kb
        if (-not $su.EulaAccepted) { try { $su.AcceptEula() } catch {} }
        Report-WU -RoundFraction 0.12 -Step ("Installing servicing stack update {0} of {1}: {2}" -f ($si+1), $ssuItems.Count, $sKbBare).Trim()
        Write-Log "  [SSU $($si+1)/$($ssuItems.Count)] Installing: $sTitle $sKbBare"
        $sFailed = $false; $sHr = ''
        try {
            $sOne = New-Object -ComObject Microsoft.Update.UpdateColl
            $sOne.Add($su) | Out-Null
            try {
                $sdl = $session.CreateUpdateDownloader()
                $sdl.Updates = $sOne
                $null = $sdl.Download()
            } catch {
                Write-Log "       SSU download warn: $_" -Level WARN -PhaseOnly
            }
            $sinst = $session.CreateUpdateInstaller()
            $sinst.Updates = $sOne
            $sinst.AllowSourcePrompts = $false
            $sir = $sinst.Install()
            $src = [int]$sir.ResultCode
            $sHresultHex = '0x{0:X8}' -f ([int64]$sir.HResult -band 0xFFFFFFFF)
            $sUrName = if ($ssuRcNames.ContainsKey($src)) { $ssuRcNames[$src] } else { 'Unknown' }
            if ($src -eq 2) {
                $ssuOk++
                Write-Log "       OK  $sKbBare ($sUrName)"
            } else {
                $ssuFail++
                $sFailed = $true; $sHr = $sHresultHex
                Write-Log "       FAIL code=$src ($sUrName) $sKbBare HResult=$sHresultHex" -Level WARN
            }
            if ($sir.RebootRequired) { $ssuReboot = $true }
        } catch {
            $ssuFail++
            $sFailed = $true; $sHr = 'exception'
            Write-Log "       SSU install exception ($sKbBare): $_" -Level WARN
        }
        if ($sFailed) {
            $ssuFailedThisRound[$sKey] = [pscustomobject]@{ kb = $sKbBare; title = $sTitle; hresult = $sHr }
        }
        if ($ssuReboot) {
            Write-Log "  Reboot required after SSU $sKbBare - deferring remaining SSUs/updates to next round"
            break
        }
    }

    # Persist SSU failures into the same failMap (one increment per SSU per round).
    foreach ($k in $ssuFailedThisRound.Keys) {
        $info = $ssuFailedThisRound[$k]
        if ($failMap.ContainsKey($k)) {
            $prev = 0; try { $prev = [int]$failMap[$k].count } catch { $prev = 0 }
            $failMap[$k] = [pscustomobject]@{ kb = $info.kb; title = $info.title; hresult = $info.hresult; count = ($prev + 1) }
        } else {
            $failMap[$k] = [pscustomobject]@{ kb = $info.kb; title = $info.title; hresult = $info.hresult; count = 1 }
        }
    }
    Save-WuFailures -Map $failMap
    Write-Log "SSU-first pass summary: $ssuOk installed, $ssuFail failed (reboot=$ssuReboot)"

    if ($ssuFail -gt 0) {
        Send-WuFailureLog -Summary (Get-FailureSummary) -Status 'error'
    }

    # SSUs usually need no reboot - but if one did, reboot now and resume next round
    # with the remaining (now-installable) updates.
    if ($ssuReboot) {
        Report-WU -RoundFraction 0.14 -Step "Servicing stack update installed - restarting to continue..." -State 'rebooting'
        Write-Log "Servicing stack update(s) require a reboot - rebooting; remaining updates continue next round"
        Write-PhaseSummary -ExitCode 3010 -Notes "$ssuOk SSU(s) installed, reboot required" -Reboot
        exit 3010
    }
    # No reboot needed: fall through to the normal install flow for everything else.
    # The installed SSUs are no longer pending; the partition below naturally skips
    # them.  (Get-FailureSummary is defined later but only CALLED on failure paths
    # that run after its definition, so no ordering issue arises here.)
}

# ---- Partition this round's pending updates into install-set vs skip-set -----
# An update whose persisted fail count has reached $MaxFailPerUpdate is EXCLUDED
# from the install collection this round (and every later round) so it can never
# reboot-loop the machine.  We just don't add it - no decline API is called.
$toInstall = New-Object System.Collections.ArrayList
$skipNow   = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $count; $i++) {
    $u   = $updates.Item($i)
    $key = Get-UpdateKey -Update $u
    $fc  = 0
    if ($failMap.ContainsKey($key)) { try { $fc = [int]$failMap[$key].count } catch { $fc = 0 } }
    if ($fc -ge $MaxFailPerUpdate) {
        [void]$skipNow.Add([pscustomobject]@{ Update = $u; Key = $key; Kb = (Get-KbBare -Update $u); FailCount = $fc })
    } else {
        [void]$toInstall.Add([pscustomobject]@{ Update = $u; Key = $key; Kb = (Get-KbBare -Update $u) })
    }
}

foreach ($s in $skipNow) {
    $kbTxt = if ($s.Kb) { $s.Kb } else { $s.Key }
    Write-Log "  SKIPPING $kbTxt (failed $($s.FailCount)x in prior rounds) - excluded from install set" -Level WARN
    Report-WU -RoundFraction 0.12 -Step ("Skipping update {0} (failed {1}x) - continuing" -f $kbTxt, $s.FailCount) -State 'warning'
}

$installCount = $toInstall.Count

# ---- Accept EULAs (install-set only) ----------------------------------------
foreach ($item in $toInstall) {
    if (-not $item.Update.EulaAccepted) { try { $item.Update.AcceptEula() } catch {} }
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
# <Title> (<KB>)" BEFORE each item AND the RESULT after each (success/fail with
# KB + HResult).  WUA still handles downloading lazily during install, so download
# progress is folded in.  A reboot requirement on ANY item ends the round.
Write-Log "Installing $installCount update(s) one at a time ($($skipNow.Count) skipped; orchestrator handles reboot)..."
$succeeded = 0; $failed = 0; $rebootNeeded = $false; $anyAborted = $false
$rcNames = @{0='NotStarted';1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'}
# Per-round record of which updates failed THIS round (keyed by update key) so we
# can increment the persisted fail map exactly once per update per round.
$failedThisRound = @{}
$lastFailKb = ''; $lastFailHr = ''

for ($i = 0; $i -lt $installCount; $i++) {
    $item  = $toInstall[$i]
    $u     = $item.Update
    $title = "$($u.Title)"
    $key   = $item.Key
    $kbBare = $item.Kb
    $kb    = Get-KbLabel -Update $u
    $short = if ($title.Length -gt 70) { $title.Substring(0,67) + '...' } else { $title }

    # Sub-percent across the install span (0.15..0.95 of this round's slice),
    # scaled by item index so the bar creeps forward as each update completes.
    $frac = 0.15 + (0.80 * ($i / [double]$installCount))
    Report-WU -RoundFraction $frac -Step ("Round {0} - installing {1} of {2}: {3} {4}" -f $Round, ($i+1), $installCount, $short, $kb).Trim()
    Write-Log "  [$($i+1)/$installCount] Installing: $title $kb"

    $thisFailed = $false; $thisHr = ''
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
        $hresultHex = '0x{0:X8}' -f ([int64]$ir.HResult -band 0xFFFFFFFF)
        $urName = if ($rcNames.ContainsKey($rc)) { $rcNames[$rc] } else { 'Unknown' }
        # ResultCode 2 = Succeeded.  4 (Failed) / 5 (Aborted) = hard failure.
        # 3 (SucceededWithErrors) = soft failure - treat as failed so it is retried
        # / eventually skipped rather than silently counted as success.
        if ($rc -eq 2) {
            $succeeded++
            Write-Log "       OK  $kbBare ($urName)"
        } else {
            $failed++
            $thisFailed = $true; $thisHr = $hresultHex
            Write-Log "       FAIL code=$rc ($urName) $kbBare HResult=$hresultHex" -Level WARN
            if ($rc -eq 5) { $anyAborted = $true }
        }
        if ($ir.RebootRequired) { $rebootNeeded = $true }
    } catch {
        $failed++
        $thisFailed = $true; $thisHr = 'exception'
        Write-Log "       install exception ($kbBare): $_" -Level WARN
    }

    if ($thisFailed) {
        $failedThisRound[$key] = [pscustomobject]@{ kb = $kbBare; title = $title; hresult = $thisHr }
        $lastFailKb = if ($kbBare) { $kbBare } else { $key }
        $lastFailHr = $thisHr
    }

    # Per-round running tally surfaced live: "Round R: installed N, FAILED M
    # (last: KB.... HResult)".  Always carries the failing KB + HResult.
    if ($failed -gt 0) {
        $tally = ("Round {0}: installed {1}, FAILED {2} (last: {3} {4})" -f $Round, $succeeded, $failed, $lastFailKb, $lastFailHr)
        Report-WU -RoundFraction $frac -Step $tally -State 'warning'
    } else {
        Report-WU -RoundFraction $frac -Step ("Round {0}: installed {1} of {2} OK" -f $Round, $succeeded, $installCount)
    }

    # If a reboot is pending, stop installing further items this round - they
    # will install on the next reboot's round (overallPercent floor keeps rising).
    if ($rebootNeeded) {
        Write-Log "  Reboot required after [$($i+1)/$installCount] - deferring remaining to next round"
        break
    }
}

# ---- Persist this round's failures (increment counts) -----------------------
foreach ($k in $failedThisRound.Keys) {
    $info = $failedThisRound[$k]
    if ($failMap.ContainsKey($k)) {
        $prev = 0; try { $prev = [int]$failMap[$k].count } catch { $prev = 0 }
        $failMap[$k] = [pscustomobject]@{ kb = $info.kb; title = $info.title; hresult = $info.hresult; count = ($prev + 1) }
    } else {
        $failMap[$k] = [pscustomobject]@{ kb = $info.kb; title = $info.title; hresult = $info.hresult; count = 1 }
    }
}
Save-WuFailures -Map $failMap

Write-Log "Round $Round install summary: $succeeded succeeded, $failed failed, $($skipNow.Count) skipped (of $count pending)"

# List of KBs we are skipping/giving up on (for the flagged completion message).
function Get-SkippedKbList {
    $kbs = @()
    foreach ($k in $failMap.Keys) {
        if ([int]$failMap[$k].count -ge $MaxFailPerUpdate) {
            $kbs += $(if ($failMap[$k].kb) { $failMap[$k].kb } else { $k })
        }
    }
    return $kbs
}

# Whenever any update failed this round, upload the WU log + summary flagged red.
if ($failed -gt 0) {
    Send-WuFailureLog -Summary (Get-FailureSummary) -Status 'error'
}

# ---- Decide next action -----------------------------------------------------
# A "stall" = this round installed 0 NEW updates yet updates are still pending.
# That means every remaining update is failing or already at the skip threshold,
# so rebooting again would loop forever.  Likewise once we hit $MaxRounds we stop.
$pendingAfter = -1
try { $pendingAfter = $searcher.Search("IsInstalled=0").Updates.Count } catch {}

$stall   = ($succeeded -eq 0) -and ($pendingAfter -ne 0)
$cappedOut = ($Round -ge $MaxRounds)

if ($rebootNeeded) {
    Report-WU -RoundFraction 0.98 -Step "Round $Round - updates installed, restarting to continue..." -State 'rebooting'
    Write-Log "Updates processed ($succeeded OK, $failed failed) - reboot required"
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded installed, $failed failed, reboot required" -Reboot
    exit 3010
}

if ($cappedOut -and $pendingAfter -ne 0) {
    # Backstop: too many rounds.  Stop rebooting for updates; finish the phase with
    # a flagged warning so imaging proceeds rather than looping indefinitely.
    $skipped = Get-SkippedKbList
    $msg = if ($skipped.Count -gt 0) {
        ("Windows Update stopped after {0} rounds - {1} update(s) never installed: {2} (see log)" -f $MaxRounds, $skipped.Count, ($skipped -join ', '))
    } else {
        ("Windows Update stopped after {0} rounds with updates still pending (see log)" -f $MaxRounds)
    }
    Report-WU -RoundFraction 1.0 -Step $msg -State 'warning'
    Write-Log $msg -Level WARN
    Send-WuFailureLog -Summary ((Get-FailureSummary) + " | ROUND CAP REACHED") -Status 'error'
    Write-PhaseSummary -ExitCode 0 -Notes "round cap ($MaxRounds) reached; $($skipped.Count) update(s) skipped"
    exit 0
}

if ($stall) {
    # No update succeeded this round and updates are still pending - they are all
    # failing or being skipped.  Treat the phase as complete-with-failures: do NOT
    # reboot again (it would loop).  Flag clearly and let the orchestrator advance.
    $failedKbs = Get-SkippedKbList
    if ($failedKbs.Count -eq 0) {
        # Nothing has yet crossed the skip threshold, but this round still made no
        # progress; list whatever has failed at least once so the tech sees it.
        foreach ($k in $failMap.Keys) { $failedKbs += $(if ($failMap[$k].kb) { $failMap[$k].kb } else { $k }) }
    }
    $n = $failedKbs.Count
    $msg = ("Windows Update finished with {0} failed update(s): {1} (see log)" -f $n, ($failedKbs -join ', '))
    Report-WU -RoundFraction 1.0 -Step $msg -State 'warning'
    Write-Log "$msg - no progress this round, stopping reboots so imaging completes" -Level WARN
    Send-WuFailureLog -Summary (Get-FailureSummary) -Status 'error'
    Write-PhaseSummary -ExitCode 0 -Notes "stall: 0 installed, $n failing update(s) skipped"
    exit 0
}

if ($anyAborted -and $succeeded -eq 0) {
    # Everything aborted with nothing installed - truly fatal, no point rebooting.
    Report-WU -RoundFraction 0.98 -Step 'Windows Update install aborted' -State 'error'
    Write-Log "Update install aborted (0/$installCount succeeded)" -Level ERROR
    Send-WuFailureLog -Summary (Get-FailureSummary) -Status 'error'
    Write-PhaseSummary -ExitCode 1 -Notes 'Install aborted'
    exit 1
}

if ($failed -gt 0 -and $succeeded -gt 0) {
    # Some updates failed but at least one succeeded (progress made) and no reboot
    # was flagged - WU often needs multiple passes.  Reboot and retry; failing ones
    # accrue fail counts and get skipped once they hit $MaxFailPerUpdate.
    Report-WU -RoundFraction 0.98 -Step ("Round {0}: installed {1}, FAILED {2} - retrying after restart..." -f $Round, $succeeded, $failed) -State 'rebooting'
    Write-Log "Some updates failed ($succeeded OK, $failed failed) - rebooting to retry" -Level WARN
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded OK, $failed failed, retrying after reboot" -Reboot
    exit 3010
}

# Installed (or nothing left to install) with no reboot flag - check for chained
# prereqs (new updates that only became visible after this batch installed).
if ($pendingAfter -gt 0) {
    Report-WU -RoundFraction 0.98 -Step "Round $Round - more updates available, restarting..." -State 'rebooting'
    Write-Log "$succeeded installed, $pendingAfter more pending - signaling reboot to re-run"
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded installed, $pendingAfter remaining" -Reboot
    exit 3010
}

# ---- Clean completion (no pending updates left) -----------------------------
# If anything ever failed across rounds, surface it on completion too (warning +
# log upload) so the tech sees it even though imaging finished successfully.
$everFailed = ($failMap.Keys.Count -gt 0)
if ($everFailed) {
    $skipped = Get-SkippedKbList
    if ($skipped.Count -gt 0) {
        $msg = ("Windows Update complete - {0} update(s) skipped after repeated failure: {1} (see log)" -f $skipped.Count, ($skipped -join ', '))
        Report-WU -RoundFraction 1.0 -Step $msg -State 'warning'
        Write-Log $msg -Level WARN
        Send-WuFailureLog -Summary (Get-FailureSummary) -Status 'error'
        Write-PhaseSummary -ExitCode 0 -Notes "complete with $($skipped.Count) skipped update(s)"
        exit 0
    }
}

Report-WU -RoundFraction 1.0 -Step 'Windows updates complete'
Write-Log "Windows updates complete ($succeeded installed this round)"
Write-PhaseSummary -ExitCode 0 -Notes "$succeeded updates installed"
exit 0
