# 03-windows-update.ps1
# Forces all available Windows updates on the target PC, reboots as needed,
# and loops until no more updates are pending.
#
# Designed to run post-OS-install (from FirstLogonCommands or manually).
# Requires PSWindowsUpdate module (auto-installed from PSGallery if missing).
#
# USAGE: .\03-windows-update.ps1
#        .\03-windows-update.ps1 -MaxRounds 5 -NoReboot

param(
    [int]$MaxRounds = 10,
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'

# --- Ensure PSWindowsUpdate is available ------------------------------------
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Write-Host '==> Installing PSWindowsUpdate module...' -ForegroundColor Cyan
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module PSWindowsUpdate -Force -Scope AllUsers
}
Import-Module PSWindowsUpdate

# --- Update loop -------------------------------------------------------------
$round = 0
do {
    $round++
    Write-Host ''
    Write-Host "==> Windows Update round $round of $MaxRounds" -ForegroundColor Cyan

    $updates = Get-WUList -MicrosoftUpdate -AcceptAll 2>$null
    if (-not $updates) {
        Write-Host '    No pending updates. System is current.' -ForegroundColor Green
        break
    }

    Write-Host "    Found $($updates.Count) update(s):" -ForegroundColor Yellow
    $updates | Select-Object KB, Title | Format-Table -AutoSize | Out-String | Write-Host

    if ($NoReboot) {
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false
    } else {
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot -Confirm:$false
        # If AutoReboot triggers, the script stops here; a restart-scheduled
        # task should re-run this script after reboot.
        break
    }

} while ($round -lt $MaxRounds)

if ($round -ge $MaxRounds) {
    Write-Host "Reached $MaxRounds rounds — check Windows Update manually." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '==> Windows Update complete for this session.' -ForegroundColor Green
