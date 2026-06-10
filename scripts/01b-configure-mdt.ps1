# 01b-configure-mdt.ps1
# Configures the MDT deployment share and generates the LiteTouch WinPE boot image.
# Run on pc-deploy as Administrator AFTER 01-setup-wds.ps1 has completed.
#
# PREREQUISITES:
#   - Windows ADK + WinPE Add-on installed (01-setup-wds.ps1)
#   - Microsoft Deployment Toolkit installed (01-setup-wds.ps1)
#   - Windows 10 or 11 ISO mounted or extracted (sources\install.wim needed)
#
# WHAT THIS DOES:
#   1. Creates the MDT deployment share at C:\DeploymentShare
#   2. Imports Windows OS source files (from a mounted ISO)
#   3. Creates a Task Sequence for unattended deployment
#   4. Generates LiteTouch WinPE boot image (.wim + .iso)
#   5. Configures tftpd64 to serve the boot image via PXE
#
# USAGE:
#   .\01b-configure-mdt.ps1
#   .\01b-configure-mdt.ps1 -IsoPath D:\  -DeployRoot C:\DeploymentShare
#
# After this script, point PXE clients at pc-deploy and they will boot LiteTouch.

param(
    # Path to a mounted Windows ISO (e.g., D:\ after mounting) - must contain sources\install.wim
    [string]$IsoPath     = '',
    [string]$DeployRoot  = 'C:\DeploymentShare',
    [string]$TftpRoot    = 'C:\tftpd64',
    # MDT deployment share name (used for the SMB share and internal MDT identifier)
    [string]$ShareName   = 'DeploymentShare$',
    # Task sequence settings
    [string]$OsVersion   = 'Win11-24H2',
    [string]$TsId        = 'WIN11-JUNIPER',
    [string]$TsName      = 'Deploy Windows 11 - Juniper',
    # Organization name embedded in WinPE
    [string]$OrgName     = 'Juniper Design'
)

$ErrorActionPreference = 'Stop'

# Auto-elevate if not running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Relaunching elevated...' -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs -Wait
    exit
}

# --- Verify MDT and ADK are installed -----------------------------------------
$mdtPath = 'C:\Program Files\Microsoft Deployment Toolkit'
$adkPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
if (-not (Test-Path $mdtPath)) { throw "MDT not found. Run 01-setup-wds.ps1 first." }
if (-not (Test-Path $adkPath)) { throw "Windows ADK not found. Run 01-setup-wds.ps1 first." }

# Load the MDT PowerShell module
Import-Module "$mdtPath\Bin\MicrosoftDeploymentToolkit.psd1" -ErrorAction Stop
Write-Host '==> MDT module loaded.' -ForegroundColor Cyan

# --- Step 1: Create the deployment share --------------------------------------
Write-Host '==> Step 1: Creating deployment share at' $DeployRoot -ForegroundColor Cyan

New-Item -Path $DeployRoot -ItemType Directory -Force | Out-Null

$existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if (-not $existing) {
    New-SmbShare -Name $ShareName -Path $DeployRoot -FullAccess 'Administrators' | Out-Null
    Write-Host "    SMB share \\$($env:COMPUTERNAME)\$ShareName created." -ForegroundColor Green
} else {
    Write-Host "    SMB share already exists." -ForegroundColor Green
}

# Create the MDT PSDrive (maps the deployment share as a PowerShell drive)
if (Get-PSDrive -Name DS001 -ErrorAction SilentlyContinue) {
    Remove-PSDrive DS001 -Force
}
New-PSDrive -Name DS001 -PSProvider MDTProvider -Root $DeployRoot -NetworkPath "\\$($env:COMPUTERNAME)\$ShareName" | Out-Null
Write-Host "    MDT PSDrive DS001 -> $DeployRoot" -ForegroundColor Green

# --- Step 2: Import OS --------------------------------------------------------
Write-Host '==> Step 2: Importing OS source files' -ForegroundColor Cyan

if (-not $IsoPath) {
    # Try to auto-detect a mounted ISO or extracted source
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)sources\install.wim" }
    if ($drives) {
        $IsoPath = $drives[0].Root
        Write-Host "    Auto-detected OS source at $IsoPath" -ForegroundColor Green
    } else {
        Write-Host '    WARN: No OS source found. Mount a Windows ISO and re-run, or specify -IsoPath.' -ForegroundColor Yellow
        Write-Host '    Skipping OS import step.' -ForegroundColor Yellow
    }
}

if ($IsoPath -and (Test-Path "$IsoPath\sources\install.wim")) {
    $osDestPath = "DS001:\Operating Systems\$OsVersion"
    if (-not (Test-Path $osDestPath)) {
        New-Item -Path 'DS001:\Operating Systems' -Enable True -Name $OsVersion -ItemType Directory | Out-Null
    }
    # Import all editions from install.wim
    Write-Host "    Importing from $IsoPath\sources\install.wim (this takes a few minutes)..."
    Import-MDTOperatingSystem -Path 'DS001:\Operating Systems' `
        -SourcePath "$IsoPath\sources" `
        -DestinationFolder $OsVersion | Out-Null
    Write-Host "    OS imported to DS001:\Operating Systems\$OsVersion" -ForegroundColor Green
} else {
    Write-Host '    WARN: Skipping OS import (no source available).' -ForegroundColor Yellow
}

# --- Step 3: Create Task Sequence ---------------------------------------------
Write-Host '==> Step 3: Creating Task Sequence' -ForegroundColor Cyan

$tsPath = 'DS001:\Task Sequences'
if (-not (Test-Path $tsPath)) {
    New-Item -Path $tsPath -Enable True -Name 'Task Sequences' -ItemType Directory | Out-Null
}

$existingTs = Get-ChildItem $tsPath -ErrorAction SilentlyContinue | Where-Object { $_.ID -eq $TsId }
if ($existingTs) {
    Write-Host "    Task Sequence '$TsId' already exists." -ForegroundColor Green
} else {
    # Find the imported OS to reference in the task sequence
    $importedOs = Get-ChildItem 'DS001:\Operating Systems' -Recurse |
        Where-Object { $_.Name -match 'Pro' -or $_.Name -match 'Professional' } |
        Select-Object -First 1

    if ($importedOs) {
        Import-MDTTaskSequence -Path $tsPath `
            -Name $TsName `
            -Template 'Client.xml' `
            -ID $TsId `
            -OperatingSystemPath "DS001:\Operating Systems\$($importedOs.Name)" `
            -FullName 'JuniperAdmin' `
            -OrgName $OrgName `
            -HomePage 'about:blank' | Out-Null
        Write-Host "    Task Sequence '$TsName' ($TsId) created." -ForegroundColor Green
    } else {
        Write-Host '    WARN: No OS found in deployment share. Import an OS first, then create task sequence manually.' -ForegroundColor Yellow
    }
}

# --- Step 4: Configure Bootstrap.ini and CustomSettings.ini ------------------
Write-Host '==> Step 4: Configuring MDT rules (Bootstrap + CustomSettings)' -ForegroundColor Cyan

$bootstrapIni = @"
[Settings]
Priority=Default

[Default]
DeployRoot=\\$($env:COMPUTERNAME)\$ShareName
UserDomain=$($env:COMPUTERNAME)
UserID=MDTUser
SkipBDDWelcome=YES
"@

$customSettingsIni = @"
[Settings]
Priority=Default
Properties=MyCustomProperty

[Default]
OSInstall=Y
SkipCapture=YES
SkipAdminPassword=YES
SkipProductKey=YES
SkipComputerBackup=YES
SkipBitLocker=YES
SkipComputerName=NO
SkipDomainMembership=YES
SkipUserData=YES
SkipLocaleSelection=YES
SkipTimeZone=YES
SkipSummary=YES
SkipFinalSummary=YES
SkipApplications=YES

TimeZoneName=Pacific Standard Time
KeyboardLocale=en-US
UserLocale=en-US
SystemLocale=en-US
UILanguage=en-US

AdminPassword=USE_1PASSWORD
JoinWorkgroup=JUNIPERDESIGN

; Do NOT reuse existing PC names - always prompt
SkipComputerName=NO
OSDComputerName=

FinishAction=RESTART
"@

$bootstrapIni | Set-Content "$DeployRoot\Control\Bootstrap.ini" -Encoding ASCII
$customSettingsIni | Set-Content "$DeployRoot\Control\CustomSettings.ini" -Encoding ASCII
Write-Host '    Bootstrap.ini and CustomSettings.ini written.' -ForegroundColor Green
Write-Host '    NOTE: Update AdminPassword in CustomSettings.ini to use 1Password at runtime.' -ForegroundColor Yellow

# --- Step 5: Generate LiteTouch WinPE boot image ----------------------------
Write-Host '==> Step 5: Generating LiteTouch WinPE boot image (this takes 10-20 minutes)...' -ForegroundColor Cyan

Update-MDTDeploymentShare -Path $DeployRoot -Force -Verbose 2>&1 | Write-Host

$bootWim = "$DeployRoot\Boot\LiteTouchPE_x64.wim"
$bootIso = "$DeployRoot\Boot\LiteTouchPE_x64.iso"

if (Test-Path $bootWim) {
    Write-Host "    Boot image generated: $bootWim" -ForegroundColor Green
} else {
    Write-Host '    WARN: Boot image not found after update. Check ADK/WinPE installation.' -ForegroundColor Yellow
}

# --- Step 6: Configure tftpd64 -----------------------------------------------
Write-Host '==> Step 6: Configuring tftpd64 for PXE' -ForegroundColor Cyan

$tftpdExe = Get-ChildItem "$TftpRoot" -Filter 'tftpd64*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($tftpdExe) {
    # Copy the LiteTouch WinPE wim to tftpd root so it's served by TFTP
    if (Test-Path $bootWim) {
        Copy-Item $bootWim "$TftpRoot\LiteTouchPE_x64.wim" -Force
        Write-Host "    Copied boot WIM to $TftpRoot" -ForegroundColor Green
    }

    # tftpd64 config file
    $tftpConfig = @"
[TFTP]
TFTP_File_Root=$TftpRoot
TFTP_Bind_Address=0.0.0.0
TFTP_Port=69
TFTP_Max_Block_Size=1468

[DHCP]
DHCP_Server=0

[PXE]
PXE_BootFile=LiteTouchPE_x64.wim
PXE_PROXY_DHCP=1
"@
    $tftpConfig | Set-Content "$TftpRoot\tftpd64.ini" -Encoding ASCII
    Write-Host "    tftpd64.ini written to $TftpRoot" -ForegroundColor Green
    Write-Host '    Run tftpd64.exe as Administrator to start the PXE server.' -ForegroundColor Yellow
} else {
    Write-Host "    WARN: tftpd64 not found in $TftpRoot. Run 01-setup-wds.ps1 first." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '==> MDT deployment share configured.' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host "  1. Review and update CustomSettings.ini at:"
Write-Host "     $DeployRoot\Control\CustomSettings.ini"
Write-Host '     - Set AdminPassword via 1Password at runtime'
Write-Host '     - Adjust TimeZone, locale, workgroup as needed'
Write-Host ''
Write-Host "  2. If OS import was skipped, mount the Windows ISO and re-run this script."
Write-Host ''
Write-Host '  3. Start tftpd64.exe as Administrator on pc-deploy.'
Write-Host '     PXE clients will boot LiteTouch WinPE and connect to this deployment share.'
Write-Host ''
Write-Host '  4. Test: PXE boot a target PC and verify it reaches the MDT menu.'
Write-Host ''
Write-Host "  Boot image: $bootWim"
if (Test-Path $bootIso) {
    Write-Host "  Boot ISO:   $bootIso  (burn to USB or use as virtual CD)"
}
