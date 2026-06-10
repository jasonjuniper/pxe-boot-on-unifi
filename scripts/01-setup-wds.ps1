# 01-setup-wds.ps1
# Installs the Windows Deployment Services role and configures it for PXE.
# Run on pc-deploy (the imaging server) as Administrator.
#
# PREREQUISITES:
#   - Server renamed to pc-deploy (run 00-rename-server.ps1 first)
#   - Static IP assigned on the LAN NIC
#   - Sufficient disk space on the WDS root drive (recommend 100 GB+)
#
# USAGE: .\01-setup-wds.ps1
#        .\01-setup-wds.ps1 -WdsRoot D:\RemoteInstall -WdsServer pc-deploy

param(
    [string]$WdsRoot   = 'C:\RemoteInstall',
    [string]$WdsServer = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

# --- Install WDS role (includes Deployment Server + Transport Server) --------
Write-Host '==> Installing WDS role...' -ForegroundColor Cyan
$feat = Get-WindowsFeature WDS
if ($feat.Installed) {
    Write-Host '    WDS already installed.' -ForegroundColor Green
} else {
    Install-WindowsFeature -Name WDS -IncludeManagementTools
    Write-Host '    WDS installed.' -ForegroundColor Green
}

# --- Initialize WDS ----------------------------------------------------------
Write-Host '==> Initializing WDS at' $WdsRoot -ForegroundColor Cyan
if (Test-Path "$WdsRoot\boot") {
    Write-Host '    WDS root already initialized.' -ForegroundColor Green
} else {
    $wdscmd = "C:\Windows\System32\wdsutil.exe"
    & $wdscmd /Initialize-Server /RemInst:"$WdsRoot" | Write-Host
}

# --- Configure WDS for standalone PXE (no AD required) ----------------------
Write-Host '==> Configuring WDS server settings...' -ForegroundColor Cyan
$wdscmd = "C:\Windows\System32\wdsutil.exe"

# Answer all clients (known + unknown) automatically
& $wdscmd /Set-Server /AnswerClients:All
# PXE response delay (seconds) — 0 = respond immediately
& $wdscmd /Set-Server /PxePromptPolicy /Known:NoPrompt /New:NoPrompt
# Set TFTP block size for faster transfers (1456 = jumbo-safe default)
& $wdscmd /Set-Server /Transport /TftpMaxBlockSize:1456

# Enable the WDS service to start automatically
Set-Service -Name WDSServer -StartupType Automatic
Start-Service -Name WDSServer -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '==> WDS setup complete.' -ForegroundColor Green
Write-Host "    WDS root     : $WdsRoot"
Write-Host "    TFTP root    : $WdsRoot\Boot"
Write-Host "    PXE boot file: boot\x64\wdsnbp.com"
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host '  1. Run 02-setup-dhcp-options.ps1 to configure the Ubiquiti router.'
Write-Host '  2. Add a boot image: wdsutil /Add-Image /ImageFile:"D:\sources\boot.wim" /ImageType:Boot'
Write-Host '  3. Add install images: wdsutil /Add-Image /ImageFile:"D:\sources\install.wim" /ImageType:Install /ImageGroup:"Windows"'
Write-Host '  4. Open WDS console and attach an unattend XML from the unattend\ folder.'
