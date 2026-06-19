# 01-setup-wds.ps1
# Sets up pc-deploy as a PXE imaging server using:
#   - Windows ADK + WinPE Add-on  (Microsoft's deployment toolkit for Win 10/11)
#   - tftpd64                      (PXE + TFTP server - runs on Windows 10/11)
#
# WDS is a Windows Server-only role and is NOT available on Windows 10/11.
# MDT was retired by Microsoft in 2025 (download URL removed). This script
# uses the correct replacement stack: WinPE + DISM (no MDT required).
#
# PREREQUISITES:
#   - Server renamed to pc-deploy (run 00-rename-server.ps1 first)
#   - Remote access enabled (run 01a-enable-remote-access.ps1 first)
#   - Run as Administrator
#   - Internet access for downloads (~3 GB total for ADK + WinPE)
#
# WHAT THIS INSTALLS:
#   1. Windows ADK (Assessment and Deployment Kit)
#   2. WinPE Add-on for ADK (boot environment)
#   (tftpd64 is installed and configured by 01c-build-winpe.ps1)
#
# After this script, run in order:
#   01c-build-winpe.ps1        -- build WinPE image + install tftpd64
#   01d-setup-deploy-share.ps1 -- create deploy$ share
#
# USAGE: .\01-setup-wds.ps1

param(
    [string]$DeployRoot = 'C:\DeploymentShare',
    [string]$TftpRoot   = 'C:\tftpd64'
)

$ErrorActionPreference = 'Stop'

Write-Host '==> pc-deploy imaging server setup (ADK + WinPE Add-on)' -ForegroundColor Cyan
Write-Host '    This will download and install ~3 GB of tools. Please be patient.' -ForegroundColor Yellow
Write-Host ''

# --- Helper: download a file if not already present --------------------------
function Get-IfMissing {
    param([string]$Url, [string]$Dest)
    if (Test-Path $Dest) {
        Write-Host "    Already downloaded: $(Split-Path $Dest -Leaf)" -ForegroundColor Green
        return
    }
    Write-Host "    Downloading $(Split-Path $Dest -Leaf)..."
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($Url, $Dest)
    Write-Host "    Done." -ForegroundColor Green
}

$tmp = "$env:TEMP\pc-deploy-setup"
New-Item -Path $tmp -ItemType Directory -Force | Out-Null

# =============================================================================
# 1. Windows ADK
# =============================================================================
Write-Host '==> Step 1: Windows ADK' -ForegroundColor Cyan

$adkInstalled = Test-Path 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
if ($adkInstalled) {
    Write-Host '    ADK already installed.' -ForegroundColor Green
} else {
    $adkSetup = "$tmp\adksetup.exe"
    # ADK for Windows 11, version 24H2
    Get-IfMissing -Url 'https://go.microsoft.com/fwlink/?linkid=2271337' -Dest $adkSetup

    Write-Host '    Installing ADK (Deployment Tools + USMT)...'
    $adkArgs = '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool'
    $p = Start-Process -FilePath $adkSetup -ArgumentList $adkArgs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "ADK setup failed with exit code $($p.ExitCode)" }
    Write-Host '    ADK installed.' -ForegroundColor Green
}

# =============================================================================
# 2. WinPE Add-on for ADK
# =============================================================================
Write-Host '==> Step 2: WinPE Add-on' -ForegroundColor Cyan

$winpeInstalled = Test-Path 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
if ($winpeInstalled) {
    Write-Host '    WinPE Add-on already installed.' -ForegroundColor Green
} else {
    $winpeSetup = "$tmp\adkwinpesetup.exe"
    # WinPE Add-on for Windows 11 24H2
    Get-IfMissing -Url 'https://go.microsoft.com/fwlink/?linkid=2271338' -Dest $winpeSetup

    Write-Host '    Installing WinPE Add-on...'
    $p = Start-Process -FilePath $winpeSetup -ArgumentList '/quiet /norestart' -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "WinPE setup failed with exit code $($p.ExitCode)" }
    Write-Host '    WinPE Add-on installed.' -ForegroundColor Green
}

Write-Host ''
Write-Host '==> All components installed.' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host '  1. Run 01c-build-winpe.ps1 to:'
Write-Host '     - Download and install tftpd64'
Write-Host '     - Build the custom WinPE boot image (with deploy.ps1 injected)'
Write-Host '     - Populate the TFTP root'
Write-Host ''
Write-Host '  2. Run 01d-setup-deploy-share.ps1 to create the deploy$ share.'
Write-Host ''
Write-Host '  3. Copy Windows ISOs / WIMs to C:\deploy\images\ on pc-deploy.'
