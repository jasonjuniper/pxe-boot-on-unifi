# 02-setup-dhcp-options.ps1
# Configures DHCP option 66 (TFTP server) and option 67 (boot file) on the
# Ubiquiti router at 192.168.0.1 so PXE clients know where to boot from.
#
# The Ubiquiti router runs EdgeOS or UniFi. This script prints the commands
# to run on the router — it does NOT automatically SSH in (credentials are
# in 1Password; use 'op run' if you want to automate the SSH step).
#
# USAGE: .\02-setup-dhcp-options.ps1
#        .\02-setup-dhcp-options.ps1 -TftpServerIp 192.168.0.10

param(
    # IP address of pc-deploy on the LAN — update to match your static IP
    [string]$TftpServerIp = '192.168.0.XXX',

    # WDS PXE boot filename (standard for WDS x64 UEFI + BIOS)
    [string]$BootFile = 'boot\x64\wdsnbp.com',

    # DHCP shared network name on EdgeOS (check with 'show dhcp server statistics')
    [string]$DhcpPool = 'LAN'
)

$ErrorActionPreference = 'Stop'

if ($TftpServerIp -match 'XXX') {
    Write-Host 'ERROR: Update $TftpServerIp to the actual static IP of pc-deploy.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== Ubiquiti EdgeOS DHCP option configuration ===' -ForegroundColor Cyan
Write-Host "TFTP server IP : $TftpServerIp"
Write-Host "Boot file      : $BootFile"
Write-Host "DHCP pool      : $DhcpPool"
Write-Host ''
Write-Host 'SSH into the router (192.168.0.1) and run these commands:' -ForegroundColor Yellow
Write-Host ''
Write-Host @"
  configure
  set service dhcp-server shared-network-name $DhcpPool subnet <YOUR_SUBNET_CIDR> bootfile-server $TftpServerIp
  set service dhcp-server shared-network-name $DhcpPool subnet <YOUR_SUBNET_CIDR> bootfile-name "$BootFile"
  commit
  save
  exit
"@
Write-Host ''
Write-Host '--- OR for UniFi Network (web UI) ---' -ForegroundColor Yellow
Write-Host @"
  Settings > Networks > LAN > DHCP > Advanced > Custom DHCP options:
    Option 66 (TFTP Server Name) = $TftpServerIp
    Option 67 (Bootfile Name)    = $BootFile
"@
Write-Host ''
Write-Host 'After saving, reboot a test PC and watch for the PXE boot prompt.' -ForegroundColor Green
Write-Host 'WDS server must be running: Get-Service WDSServer' -ForegroundColor Green
