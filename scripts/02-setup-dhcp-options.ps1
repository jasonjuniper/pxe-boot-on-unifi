# 02-setup-dhcp-options.ps1
# Documents and verifies the DHCP/PXE configuration for pc-deploy.
#
# Stack: tftpd64 (proxy DHCP) + WinPE — NOT WDS.
#
# WHAT IS CONFIGURED ON THE UBIQUITI (192.168.0.1):
#   - Fixed IP reservation: pc-deploy (c8:f7:50:a3:34:ed) → 192.168.5.141
#   - DHCP option 66 (TFTP Server Name): 192.168.5.141
#   - DHCP option 67 (Boot File): EFI\Boot\bootx64.efi
#     (set manually in UniFi > Networks > Default > DHCP Options)
#
# tftpd64 runs in ProxyDHCP=1 mode (port 4011) so it intercepts PXE requests
# and tells clients to load EFI\Boot\bootx64.efi from 192.168.5.141 via TFTP.
# The Ubiquiti option 67 is a fallback; the proxy DHCP response takes precedence.
#
# USAGE: .\02-setup-dhcp-options.ps1

param(
    [string]$TftpServerIp = '192.168.5.141'
)

$ErrorActionPreference = 'SilentlyContinue'

Write-Host ''
Write-Host '=== PXE / DHCP configuration status ===' -ForegroundColor Cyan
Write-Host "TFTP server (pc-deploy) : $TftpServerIp"
Write-Host "Option 66               : $TftpServerIp"
Write-Host "Option 67               : EFI\Boot\bootx64.efi  (Ubiquiti + tftpd64 proxy DHCP)"
Write-Host ''

# Verify tftpd64 service
$tftpSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
if ($tftpSvc) {
    $color = if ($tftpSvc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
    Write-Host "tftpd64 service         : $($tftpSvc.Status)" -ForegroundColor $color
    if ($tftpSvc.Status -ne 'Running') {
        Write-Host '  Start it with: Start-Service tftpd64' -ForegroundColor Yellow
    }
} else {
    Write-Host 'tftpd64 service         : NOT INSTALLED - run 01c-build-winpe.ps1 first' -ForegroundColor Red
}

# Verify UDP 69 is listening
$udp69 = netstat -an 2>$null | Select-String ':69 '
$color = if ($udp69) { 'Green' } else { 'Red' }
Write-Host "UDP port 69 (TFTP)      : $(if ($udp69) { 'Listening' } else { 'NOT listening' })" -ForegroundColor $color

# Verify boot file is present
$bootFile = "$TftpServerIp"   # just a placeholder — test the local path
$localBoot = 'C:\tftpd64\EFI\Boot\bootx64.efi'
$color = if (Test-Path $localBoot) { 'Green' } else { 'Red' }
Write-Host "Boot file present       : $(if (Test-Path $localBoot) { $localBoot } else { "MISSING: $localBoot" })" -ForegroundColor $color

$wimPath = 'C:\tftpd64\sources\boot.wim'
$color = if (Test-Path $wimPath) { 'Green' } else { 'Red' }
Write-Host "WinPE boot.wim          : $(if (Test-Path $wimPath) { 'Present' } else { "MISSING: $wimPath" })" -ForegroundColor $color

Write-Host ''
Write-Host 'To test PXE boot: boot a target PC over the network (F12 / PXE).' -ForegroundColor Green
Write-Host "It should receive an IP, then TFTP-load EFI\Boot\bootx64.efi from $TftpServerIp." -ForegroundColor Green
