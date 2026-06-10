# 01-setup-wds.ps1
# Sets up pc-deploy as a PXE imaging server using:
#   - Windows ADK + WinPE Add-on  (Microsoft's deployment toolkit for Win 10/11)
#   - Microsoft Deployment Toolkit (MDT)
#   - tftpd64                      (PXE + TFTP server - runs on Windows 10/11)
#
# WDS is a Windows Server-only role and is NOT available on Windows 10/11.
# This script is the correct approach for a Windows 11 imaging server.
#
# PREREQUISITES:
#   - Server renamed to pc-deploy (run 00-rename-server.ps1 first)
#   - Remote access enabled (run 01a-enable-remote-access.ps1 first)
#   - Run as Administrator
#   - Internet access for downloads (~5 GB total for ADK + WinPE + MDT)
#
# WHAT THIS INSTALLS:
#   1. Windows ADK (Assessment and Deployment Kit)
#   2. WinPE Add-on for ADK (boot environment)
#   3. Microsoft Deployment Toolkit (MDT)
#   4. tftpd64 (PXE/TFTP server - replaces WDS on Windows 10/11)
#
# After this script, run: 01b-configure-mdt.ps1
#
# USAGE: .\01-setup-wds.ps1

param(
    [string]$DeployRoot = 'C:\DeploymentShare',
    [string]$TftpRoot   = 'C:\tftpd64'
)

$ErrorActionPreference = 'Stop'

Write-Host '==> pc-deploy imaging server setup (ADK + MDT + tftpd64)' -ForegroundColor Cyan
Write-Host '    This will download and install ~5 GB of tools. Please be patient.' -ForegroundColor Yellow
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

# =============================================================================
# 3. Microsoft Deployment Toolkit (MDT)
# =============================================================================
Write-Host '==> Step 3: Microsoft Deployment Toolkit' -ForegroundColor Cyan

$mdtInstalled = Test-Path 'C:\Program Files\Microsoft Deployment Toolkit'
if ($mdtInstalled) {
    Write-Host '    MDT already installed.' -ForegroundColor Green
} else {
    $mdtMsi = "$tmp\MicrosoftDeploymentToolkit_x64.msi"
    # MDT 8456 - current release
    Get-IfMissing -Url 'https://download.microsoft.com/download/3/3/9/339BE62D-B4B8-4956-B58D-73C4685FC492/MicrosoftDeploymentToolkit_x64.msi' -Dest $mdtMsi

    Write-Host '    Installing MDT...'
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$mdtMsi`" /quiet /norestart" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "MDT setup failed with exit code $($p.ExitCode)" }
    Write-Host '    MDT installed.' -ForegroundColor Green
}

# =============================================================================
# 4. tftpd64 (PXE + TFTP server)
# =============================================================================
Write-Host '==> Step 4: tftpd64 (PXE/TFTP server)' -ForegroundColor Cyan

$tftpdExe = "$TftpRoot\tftpd64.exe"
$tftpdSvc  = Get-Service -Name tftpd64 -ErrorAction SilentlyContinue

if ($tftpdSvc) {
    Write-Host '    tftpd64 service already installed.' -ForegroundColor Green
} elseif (Test-Path $tftpdExe) {
    Write-Host '    tftpd64 binary found at $TftpRoot. Skipping download.' -ForegroundColor Green
} else {
    # tftpd64 portable (no installer needed)
    $tftpdZip = "$tmp\tftpd64.zip"
    Get-IfMissing -Url 'https://github.com/PFei-He/tftpd64/raw/master/tftpd64/tftpd64.zip' -Dest $tftpdZip

    Write-Host "    Extracting to $TftpRoot..."
    New-Item -Path $TftpRoot -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $tftpdZip -DestinationPath $TftpRoot -Force
    Write-Host '    tftpd64 extracted.' -ForegroundColor Green
}

Write-Host ''
Write-Host '==> All components installed.' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host '  1. Run 01b-configure-mdt.ps1 to create the MDT deployment share'
Write-Host '     and generate the LiteTouch WinPE boot image.'
Write-Host ''
Write-Host '  2. Configure tftpd64:'
Write-Host "     - Open $TftpRoot\tftpd64.exe as Administrator"
Write-Host '     - Set TFTP root to the MDT Boot folder (e.g. C:\DeploymentShare\Boot)'
Write-Host '     - Enable PXE proxy mode (DHCP proxy, not standalone DHCP)'
Write-Host '     - Set boot file to: LiteTouchPE_x64.wim'
Write-Host ''
Write-Host '  3. Add Windows OS source files to MDT:'
Write-Host "     - Mount Windows ISO and copy sources\install.wim to"
Write-Host "       $DeployRoot\Operating Systems\"
Write-Host ''
Write-Host '  4. Import OS into MDT and create a Task Sequence'
Write-Host '     (use the Deployment Workbench GUI on this machine or from ENG-2 via RDP).'
