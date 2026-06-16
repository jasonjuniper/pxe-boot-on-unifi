# 03-windows-update.ps1
# Installs all pending Windows updates.
# Part of the Juniper automated imaging pipeline - runs via orchestrator.ps1.
#
# Exit codes (read by orchestrator.ps1):
#   0    - no more pending updates; phase complete
#   3010 - updates were installed; reboot required to continue
#   1    - fatal error (orchestrator will log and advance anyway)
#
# NOTE: Do NOT add -AutoReboot to Install-WindowsUpdate here.
# The orchestrator reads the exit code and handles the reboot itself,
# so it can log the event and update phase.json before rebooting.

$ErrorActionPreference = 'Stop'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'windows-update'
Write-PhaseHeader -Description 'Windows Update'

# ---- Ensure PSWindowsUpdate is available ------------------------------------
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Write-Log "Installing PSWindowsUpdate module..."
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
        Write-Log "PSWindowsUpdate installed"
    } catch {
        Write-Log "Failed to install PSWindowsUpdate: $_" -Level ERROR
        Write-PhaseSummary -ExitCode 1 -Notes "PSWindowsUpdate install failed"
        exit 1
    }
}
Import-Module PSWindowsUpdate

# ---- Check for pending updates ----------------------------------------------
Write-Log "Checking for pending updates..."

$updates = $null
try {
    $updates = Get-WUList -MicrosoftUpdate -AcceptAll 2>$null
} catch {
    Write-Log "Get-WUList error: $_" -Level WARN
}

if (-not $updates -or $updates.Count -eq 0) {
    Write-Log "No pending updates - system is current"
    Write-PhaseSummary -ExitCode 0 -Notes "0 updates pending"
    exit 0
}

Write-Log "Found $($updates.Count) pending update(s):"
foreach ($u in $updates) {
    Write-Log "  $($u.KB)  $($u.Title)" -PhaseOnly
}

# ---- Install updates (no auto-reboot - orchestrator handles the reboot) -----
Write-Log "Installing $($updates.Count) update(s)..."
try {
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false
} catch {
    Write-Log "Install-WindowsUpdate error: $_" -Level WARN
}

# Check if a reboot is pending after the install
$rebootPending = $false
try {
    $rebootPending = (Get-WURebootStatus -Silent).RebootRequired
} catch {
    # Fallback: check registry
    $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}

if ($rebootPending) {
    Write-Log "$($updates.Count) update(s) installed - reboot required"
    Write-PhaseSummary -ExitCode 3010 -Notes "$($updates.Count) updates installed" -Reboot
    exit 3010
} else {
    # Updates installed but no reboot required - check again to be safe
    $remaining = $null
    try { $remaining = Get-WUList -MicrosoftUpdate -AcceptAll 2>$null } catch {}
    if ($remaining -and $remaining.Count -gt 0) {
        Write-Log "$($updates.Count) installed, $($remaining.Count) still pending - signaling reboot to re-run"
        Write-PhaseSummary -ExitCode 3010 -Notes "$($updates.Count) installed, $($remaining.Count) remaining" -Reboot
        exit 3010
    }
    Write-Log "$($updates.Count) update(s) installed, no reboot required"
    Write-PhaseSummary -ExitCode 0 -Notes "$($updates.Count) updates installed"
    exit 0
}
