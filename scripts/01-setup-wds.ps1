# 01-setup-wds.ps1
# Installs the Windows Deployment Services role and configures it for PXE.
# Run on pc-deploy (the imaging server) as Administrator.
#
# PREREQUISITES:
#   - Server renamed to pc-deploy (run 00-rename-server.ps1 first)
#   - Static IP assigned on the LAN NIC
#   - Sufficient disk space on the WDS root drive (recommend 100 GB+)
#   - Scripts on the machine - bootstrap without git/winget:
#       powershell -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest 'https://github.com/jasonjuniper/pc-imaging-server/archive/refs/heads/main.zip' -OutFile $env:TEMP\d.zip; Expand-Archive $env:TEMP\d.zip $env:TEMP\dsrc -Force; New-Item C:\deploy -ItemType Directory -Force | Out-Null; Copy-Item $env:TEMP\dsrc\pc-imaging-server-main\* C:\deploy -Recurse -Force"
#
# This script installs winget and git on the server, so future updates can use:
#   cd C:\deploy && git pull
#
# USAGE: .\01-setup-wds.ps1
#        .\01-setup-wds.ps1 -WdsRoot D:\RemoteInstall -WdsServer pc-deploy

param(
    [string]$WdsRoot   = 'C:\RemoteInstall',
    [string]$WdsServer = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

# --- Install server-side prerequisites (git, winget App Installer) -----------
Write-Host '==> Installing server prerequisites...' -ForegroundColor Cyan

# winget (App Installer) - needed to install packages on this server
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    Write-Host '    winget already available.' -ForegroundColor Green
} else {
    Write-Host '    Installing winget via Microsoft Store (App Installer)...'
    try {
        # Trigger Store update for App Installer (works on Win10 1709+ / Win11)
        Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' -ErrorAction SilentlyContinue
        Write-Host '    WARN: winget is not present. The Microsoft Store has been opened.' -ForegroundColor Yellow
        Write-Host '    Install "App Installer" from the Store, then re-run this script.' -ForegroundColor Yellow
        Write-Host '    Continuing with remaining steps...' -ForegroundColor Yellow
    } catch {
        Write-Host "    WARN: Could not open Store: $_" -ForegroundColor Yellow
    }
}

# Git - needed for pulling script updates from GitHub onto this server
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Write-Host '    git already available.' -ForegroundColor Green
} else {
    Write-Host '    Installing git...'
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent
            Write-Host '    git installed.' -ForegroundColor Green
        } else {
            Write-Host '    WARN: winget not available; install git manually from https://git-scm.com' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    WARN: git install failed: $_" -ForegroundColor Yellow
    }
}

# --- Install WDS (works on both Windows Server and Windows 10/11) ------------
Write-Host '==> Installing WDS...' -ForegroundColor Cyan
$isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1   # 1 = Workstation

if ($isServer) {
    # Windows Server: use Server Manager cmdlets
    $feat = Get-WindowsFeature WDS
    if ($feat.Installed) {
        Write-Host '    WDS already installed.' -ForegroundColor Green
    } else {
        Install-WindowsFeature -Name WDS -IncludeManagementTools
        Write-Host '    WDS installed.' -ForegroundColor Green
    }
} else {
    # Windows 10/11: use DISM optional features
    $wds = Get-WindowsOptionalFeature -Online -FeatureName WDS -ErrorAction SilentlyContinue
    if ($wds -and $wds.State -eq 'Enabled') {
        Write-Host '    WDS already enabled.' -ForegroundColor Green
    } else {
        Write-Host '    Enabling WDS via DISM...'
        Enable-WindowsOptionalFeature -Online -FeatureName WDS -All -NoRestart | Out-Null
        Write-Host '    WDS enabled.' -ForegroundColor Green
    }
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
# PXE response delay (seconds) - 0 = respond immediately
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

# --- Remote management setup -------------------------------------------------
# Run this once so ENG-2 (or any management PC) can push files and run scripts
# without needing to sit at the imaging server again.

Write-Host ''
Write-Host '==> Enabling remote management...' -ForegroundColor Cyan

# 1. Enable WinRM so Invoke-Command / Copy-Item -ToSession work from ENG-2
Write-Host '    Enabling WinRM (PowerShell remoting)...'
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
Set-Service -Name WinRM -StartupType Automatic
Write-Host '    WinRM enabled.' -ForegroundColor Green

# 2. Allow local accounts to access admin shares (C$) over the network.
#    Windows blocks this by default via UAC token filtering.
Write-Host '    Enabling local-account admin share access (LocalAccountTokenFilterPolicy)...'
$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $regPath -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord -Force
Write-Host '    Admin shares enabled for local accounts.' -ForegroundColor Green

# 3. Create the deploy$ share (scripts, packages, unattend XMLs go here)
Write-Host '    Creating deploy$ share...'
$deployPath = 'C:\deploy'
New-Item -Path $deployPath -ItemType Directory -Force | Out-Null
$existing = Get-SmbShare -Name 'deploy$' -ErrorAction SilentlyContinue
if (-not $existing) {
    New-SmbShare -Name 'deploy$' -Path $deployPath -FullAccess 'Administrators' | Out-Null
}
Write-Host "    \\$($env:COMPUTERNAME)\deploy$ -> $deployPath" -ForegroundColor Green

# 4. Open WinRM and SMB through the firewall
Write-Host '    Opening firewall for WinRM and SMB...'
Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'  -ErrorAction SilentlyContinue
Write-Host '    Firewall rules updated.' -ForegroundColor Green

Write-Host ''
Write-Host '==> Remote management ready.' -ForegroundColor Green
Write-Host '    From ENG-2 you can now:'
Write-Host '      Copy-Item -Path .\scripts\* -Destination \\pc-deploy\deploy$\scripts\ -Recurse'
Write-Host '      $s = New-PSSession -ComputerName pc-deploy -Credential (Get-Credential)'
Write-Host '      Invoke-Command -Session $s -FilePath .\scripts\03-windows-update.ps1'
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host '  1. Add a boot image: wdsutil /Add-Image /ImageFile:"D:\sources\boot.wim" /ImageType:Boot'
Write-Host '  2. Add install images: wdsutil /Add-Image /ImageFile:"D:\sources\install.wim" /ImageType:Install /ImageGroup:"Windows"'
Write-Host '  3. Open WDS console and attach an unattend XML from the unattend\ folder.'
