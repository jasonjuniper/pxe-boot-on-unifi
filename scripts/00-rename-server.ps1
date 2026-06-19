# 00-rename-server.ps1
# Renames the imaging server to 'pc-deploy' and schedules a reboot.
# Run once on the server itself (via RDP or local console).
# After reboot, reconnect via RDP to pc-deploy (update your hosts file or
# let DNS/mDNS resolve the new name).
#
# USAGE: .\00-rename-server.ps1
#        .\00-rename-server.ps1 -NewName pc-deploy -Force

param(
    [string]$NewName = 'pc-deploy',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$current = $env:COMPUTERNAME

if ($current -eq $NewName) {
    Write-Host "Server is already named '$NewName'. Nothing to do." -ForegroundColor Green
    exit 0
}

Write-Host "Current name : $current" -ForegroundColor Cyan
Write-Host "New name     : $NewName" -ForegroundColor Cyan

if (-not $Force) {
    $confirm = Read-Host "Rename and reboot? [y/N]"
    if ($confirm -notmatch '^[Yy]') { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
}

Rename-Computer -NewName $NewName -Force
Write-Host "Renamed. Rebooting in 10 seconds - reconnect to '$NewName' after restart." -ForegroundColor Yellow
Start-Sleep 10
Restart-Computer -Force
