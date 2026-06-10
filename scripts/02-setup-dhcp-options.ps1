# 02-setup-dhcp-options.ps1
# Documents the DHCP PXE configuration applied to the Ubiquiti UniFi router at
# 192.168.0.1. Configuration was applied manually via the UniFi web UI.
#
# WHAT WAS CONFIGURED (already done):
#   - Fixed IP reservation: pc-deploy (c8:f7:50:a3:34:ed) → 192.168.5.141
#   - DHCP option 66 (TFTP Server): 192.168.5.141
#   - DHCP option 67 (Boot File): automatically provided by UniFi when
#     the Network Boot / TFTP option is enabled - no manual entry needed.
#
# Run this script to verify the WDS service is running and ready.
#
# USAGE: .\02-setup-dhcp-options.ps1
#        .\02-setup-dhcp-options.ps1 -TftpServerIp 192.168.5.141

param(
    # Static IP of pc-deploy (fixed reservation set in UniFi)
    [string]$TftpServerIp = '192.168.5.141'
)

$ErrorActionPreference = 'SilentlyContinue'

Write-Host ''
Write-Host '=== PXE / DHCP configuration status ===' -ForegroundColor Cyan
Write-Host "TFTP server (pc-deploy) : $TftpServerIp"
Write-Host "Option 66               : $TftpServerIp  [set in UniFi > Networks > Default > DHCP > TFTP Server]"
Write-Host "Option 67               : auto (UniFi supplies boot\x64\wdsnbp.com when Network Boot is enabled)"
Write-Host ''

# Verify WDS is running on this machine
$wds = Get-Service -Name WDSServer -ErrorAction SilentlyContinue
if ($wds) {
    $color = if ($wds.Status -eq 'Running') { 'Green' } else { 'Yellow' }
    Write-Host "WDS service status      : $($wds.Status)" -ForegroundColor $color
    if ($wds.Status -ne 'Running') {
        Write-Host '  Start it with: Start-Service WDSServer' -ForegroundColor Yellow
    }
} else {
    Write-Host 'WDS service             : NOT INSTALLED - run 01-setup-wds.ps1 first' -ForegroundColor Red
}

Write-Host ''
Write-Host 'To test PXE boot: boot a target PC over the network (F12 / PXE).' -ForegroundColor Green
Write-Host 'It should receive an IP from 192.168.5.x and TFTP-load from 192.168.5.141.' -ForegroundColor Green
