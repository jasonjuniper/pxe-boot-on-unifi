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

param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'windows-update'
Write-PhaseHeader -Description 'Windows Update'

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
    Write-PhaseSummary -ExitCode 1 -Notes 'WUA COM init failed'
    exit 1
}

$updates = $result.Updates
$count   = $updates.Count

if ($count -eq 0) {
    Write-Log 'No pending updates - system is current'
    Write-PhaseSummary -ExitCode 0 -Notes '0 updates pending'
    exit 0
}

Write-Log "Found $count pending update(s):"
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

# ---- Download ---------------------------------------------------------------
Write-Log "Downloading $count update(s)..."
try {
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $updates
    $dlResult = $dl.Download()
    Write-Log "Download result code: $($dlResult.ResultCode)" -PhaseOnly
} catch {
    Write-Log "Download error: $_" -Level WARN
    # Non-fatal - attempt install anyway (some updates may already be cached)
}

# ---- Install ----------------------------------------------------------------
Write-Log "Installing $count update(s) (orchestrator handles reboot)..."
$installResult = $null
try {
    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $updates
    $inst.AllowSourcePrompts = $false
    $installResult = $inst.Install()
} catch {
    Write-Log "Install error: $_" -Level ERROR
    Write-PhaseSummary -ExitCode 1 -Notes "Install exception: $_"
    exit 1
}

# ResultCode: 0=NotStarted 1=InProgress 2=Succeeded 3=SucceededWithErrors 4=Failed 5=Aborted
# HResult meanings: 0x00000000=OK, 0x80240022=No Updates, 0x8024000C=UpdateNotInstalled,
#                   0x80070005=Access Denied, 0x8024402C=Network, 0x80240017=Uninstallable
$rc = $installResult.ResultCode
$rcNames = @{0='NotStarted';1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'}
Write-Log "Install result: $($rcNames[$rc]) (code=$rc) | RebootRequired=$($installResult.RebootRequired)"

# Log per-update results so failures can be diagnosed without reading Event Viewer
$succeeded = 0; $failed = 0
try {
    for ($i = 0; $i -lt $count; $i++) {
        $ur = $installResult.GetUpdateResult($i)
        $un = $updates.Item($i).Title
        if ($ur.ResultCode -eq 2) {
            $succeeded++
        } else {
            $failed++
            $hresultHex = '0x{0:X8}' -f ([int64]$ur.HResult -band 0xFFFFFFFF)
            $urName = if ($rcNames.ContainsKey([int]$ur.ResultCode)) { $rcNames[[int]$ur.ResultCode] } else { 'Unknown' }
            Write-Log "  FAIL [$($i+1)/$count] $un" -Level WARN
            Write-Log "       code=$($ur.ResultCode) ($urName) HResult=$hresultHex" -Level WARN
        }
    }
    if ($failed -gt 0) {
        Write-Log "Summary: $succeeded succeeded, $failed failed out of $count" -Level WARN
    }
} catch {
    Write-Log "Could not enumerate per-update results: $_ (overall result above is still valid)" -Level WARN
    $succeeded = 0; $failed = 0
}

if ($installResult.RebootRequired) {
    Write-Log "$count update(s) processed ($succeeded OK, $failed failed) - reboot required"
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded installed, $failed failed, reboot required" -Reboot
    exit 3010
}

if ($rc -eq 5) {
    # Aborted - truly fatal, no point rebooting
    Write-Log "Update install aborted (code=5, $succeeded/$count succeeded)" -Level ERROR
    Write-PhaseSummary -ExitCode 1 -Notes "Install aborted (code=5)"
    exit 1
}

if ($rc -eq 4) {
    # Some updates failed - Windows Update often needs multiple passes.
    # Reboot and retry rather than giving up; the search on next round
    # will skip already-installed updates and retry the rest.
    Write-Log "Some updates failed ($succeeded/$count succeeded) - rebooting to retry" -Level WARN
    Write-PhaseSummary -ExitCode 3010 -Notes "$succeeded/$count OK, $failed failed, retrying after reboot" -Reboot
    exit 3010
}

# Installed but no reboot flag - check for chained prereqs
$remaining = 0
try {
    $remaining = $searcher.Search("IsInstalled=0").Updates.Count
} catch {}

if ($remaining -gt 0) {
    Write-Log "$count installed, $remaining more pending - signaling reboot to re-run"
    Write-PhaseSummary -ExitCode 3010 -Notes "$count installed, $remaining remaining" -Reboot
    exit 3010
}

Write-Log "$count update(s) installed successfully"
Write-PhaseSummary -ExitCode 0 -Notes "$count updates installed"
exit 0
