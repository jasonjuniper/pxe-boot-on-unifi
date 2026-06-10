# 03-windows-update.ps1
# Forces all available Windows updates on the target PC, reboots as needed,
# and loops until no more updates are pending.
#
# Designed to run post-OS-install (from MDT Task Sequence, FirstLogonCommands, or manually).
# Requires PSWindowsUpdate module (auto-installed from PSGallery if missing).
#
# REBOOT PERSISTENCE:
#   When a reboot is required, this script registers itself in RunOnce so it
#   automatically resumes after the machine comes back up. It also copies itself
#   to C:\Windows\Temp\03-windows-update.ps1 so the RunOnce entry doesn't depend
#   on the \\pc-deploy share being immediately accessible post-reboot.
#
# USAGE: .\03-windows-update.ps1
#        .\03-windows-update.ps1 -MaxRounds 5 -NoReboot

param(
    [int]$MaxRounds = 10,
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'

$RunOnceName  = 'JuniperWindowsUpdate'
$LocalCopy    = 'C:\Windows\Temp\03-windows-update.ps1'
$RunOnceValue = "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File `"$LocalCopy`""

# Auto-elevate if not running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Relaunching elevated...' -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs -Wait
    exit
}

# Remove our own RunOnce entry if we were launched by it (cleanup)
$runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
if (Get-ItemProperty -Path $runOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $runOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    Write-Host '==> Resumed after reboot (RunOnce entry cleared).' -ForegroundColor Cyan
}

# Stage a local copy so the RunOnce entry doesn't need the share after reboot
$scriptSource = $MyInvocation.MyCommand.Path
if ($scriptSource -and (Test-Path $scriptSource) -and $scriptSource -ne $LocalCopy) {
    Copy-Item $scriptSource $LocalCopy -Force -ErrorAction SilentlyContinue
}

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
        # Clean up the local staged copy
        Remove-Item $LocalCopy -Force -ErrorAction SilentlyContinue
        break
    }

    Write-Host "    Found $($updates.Count) update(s):" -ForegroundColor Yellow
    $updates | Select-Object KB, Title | Format-Table -AutoSize | Out-String | Write-Host

    if ($NoReboot) {
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false
    } else {
        # Register RunOnce so the script resumes after reboot
        Set-ItemProperty -Path $runOnceKey -Name $RunOnceName -Value $RunOnceValue
        Write-Host ''
        Write-Host "    RunOnce registered: will resume after reboot." -ForegroundColor Yellow
        Write-Host '    Rebooting in 15 seconds (Ctrl+C to cancel)...' -ForegroundColor Yellow
        Start-Sleep 15

        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot -Confirm:$false
        # If AutoReboot fires, execution stops here.
        # The RunOnce entry above ensures we pick back up after the reboot.
        break
    }

} while ($round -lt $MaxRounds)

if ($round -ge $MaxRounds) {
    Write-Host "Reached $MaxRounds rounds - check Windows Update manually." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '==> Windows Update complete for this session.' -ForegroundColor Green
