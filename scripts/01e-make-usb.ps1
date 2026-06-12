# 01e-make-usb.ps1 — Write a bootable WinPE USB drive
#
# Runs ON ENG-2 (this machine) as Administrator.
# Pulls the WinPE media tree from pc-deploy, formats a USB drive FAT32,
# and copies the media tree so the USB is UEFI-bootable (no special boot
# sector tool needed — UEFI firmware finds EFI\Boot\bootx64.efi on any
# FAT32 volume).
#
# Usage:
#   .\scripts\01e-make-usb.ps1
#   .\scripts\01e-make-usb.ps1 -DiskNumber 2     # skip the disk picker
#
# Requirements:
#   - Run as Administrator
#   - pc-deploy (192.168.5.141) reachable and deploy$ share accessible
#   - USB drive inserted (>= 1 GB)

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]   $DiskNumber = -1,         # -1 = interactive picker
    [string] $DeployServer = '192.168.5.141',
    [string] $MediaSource  = $null    # override source path (default: \\server\deploy$\winpe-media)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "  >> $msg" -ForegroundColor Cyan }
function Write-OK  ([string]$msg) { Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  !! $msg"  -ForegroundColor Yellow }
function Write-Err ([string]$msg) { Write-Host "  ERROR: $msg" -ForegroundColor Red }

# ─── Admin check ─────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err 'This script must be run as Administrator.'
    exit 1
}

# ─── Locate WinPE media source ────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Juniper Design  -  WinPE USB Writer       ' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ''

if (-not $MediaSource) {
    $MediaSource = "\\$DeployServer\deploy$\winpe-media"
}

Write-Step "Checking WinPE media source: $MediaSource"

# Map the deploy share if needed
$deployShare = "\\$DeployServer\deploy$"
try { net use $deployShare /persistent:no *>$null } catch {}

if (-not (Test-Path $MediaSource)) {
    # Fallback: check if media tree is in tftpd64 share
    $tftpShare = "\\$DeployServer\tftpd64$"
    try { net use $tftpShare /persistent:no *>$null } catch {}

    if (Test-Path "$tftpShare\EFI\Boot\bootx64.efi") {
        $MediaSource = $tftpShare
        Write-Warn "deploy$\winpe-media not found; using tftpd64$ as source."
    } else {
        Write-Err "Cannot find WinPE media at $MediaSource or $tftpShare"
        Write-Host ''
        Write-Host '  Run 01c-build-winpe.ps1 on pc-deploy first, then run' -ForegroundColor Yellow
        Write-Host '  01d-setup-deploy-share.ps1 to expose the media tree on the share.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  If tftpd64$ share is not exposed, create it on pc-deploy:' -ForegroundColor Yellow
        Write-Host '    New-SmbShare -Name tftpd64$ -Path C:\tftpd64 -FullAccess Everyone' -ForegroundColor DarkGray
        exit 1
    }
}

# Quick sanity — bootloader must exist
if (-not (Test-Path "$MediaSource\EFI\Boot\bootx64.efi")) {
    Write-Err "WinPE media source looks incomplete (missing EFI\Boot\bootx64.efi): $MediaSource"
    exit 1
}
Write-OK "WinPE media source looks good."

# ─── Pick USB disk ────────────────────────────────────────────────────────────
Write-Step 'Enumerating removable disks...'
$removableDisks = Get-Disk | Where-Object BusType -in 'USB','SCSI' | Sort-Object Number

if (-not $removableDisks) {
    Write-Err 'No USB or removable disks found. Plug in the USB drive and retry.'
    exit 1
}

Write-Host ''
Write-Host '  Removable disks detected:' -ForegroundColor Yellow
foreach ($d in $removableDisks) {
    $gb = [math]::Round($d.Size / 1GB, 1)
    Write-Host "    Disk $($d.Number) : $($d.FriendlyName)  ($gb GB)  Model=$($d.Model)"
}
Write-Host ''

if ($DiskNumber -lt 0) {
    $inputStr = Read-Host '  Enter disk number to use (WARNING: ALL DATA WILL BE ERASED)'
    if (-not ($inputStr -match '^\d+$')) {
        Write-Err 'Invalid input.'
        exit 1
    }
    $DiskNumber = [int]$inputStr
}

$targetDisk = $removableDisks | Where-Object Number -eq $DiskNumber
if (-not $targetDisk) {
    Write-Err "Disk $DiskNumber not found in removable disk list. Aborting."
    exit 1
}

$gb = [math]::Round($targetDisk.Size / 1GB, 1)
Write-Host ''
Write-Host "  Target: Disk $DiskNumber — $($targetDisk.FriendlyName) ($gb GB)" -ForegroundColor Yellow
Write-Host ''
$confirm = Read-Host '  Type YES to erase this disk and write WinPE'
if ($confirm -ne 'YES') {
    Write-Host '  Aborted.' -ForegroundColor DarkGray
    exit 0
}

# ─── Format USB with diskpart ─────────────────────────────────────────────────
Write-Step "Formatting Disk $DiskNumber as FAT32 (MBR, single partition)..."

$diskpartScript = @"
select disk $DiskNumber
clean
create partition primary
select partition 1
active
format fs=fat32 quick label="WINPE"
assign
exit
"@

$dpScriptPath = "$env:TEMP\winpe-usb-diskpart.txt"
[System.IO.File]::WriteAllText($dpScriptPath, $diskpartScript)

$outFile = "$env:TEMP\diskpart-out.txt"
$errFile = "$env:TEMP\diskpart-err.txt"
$p = Start-Process -FilePath 'diskpart.exe' `
    -ArgumentList "/s `"$dpScriptPath`"" `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile `
    -RedirectStandardError  $errFile
$diskpartOut = Get-Content $outFile -Raw
$diskpartErr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue

if ($p.ExitCode -ne 0) {
    Write-Err "diskpart failed (exit $($p.ExitCode)):"
    Write-Host $diskpartOut
    Write-Host $diskpartErr
    exit 1
}
Write-OK 'Disk formatted.'

# Give Windows a moment to assign a drive letter
Start-Sleep 3

# Find the newly assigned drive letter
$usbVolume = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'WINPE' -and $_.DriveType -eq 'Removable' } |
             Select-Object -First 1
if (-not $usbVolume) {
    Write-Err 'Cannot find the WINPE volume after format. Check Disk Management.'
    exit 1
}
$usbDrive = "$($usbVolume.DriveLetter):"
Write-OK "USB volume is at $usbDrive"

# ─── Copy WinPE media tree ────────────────────────────────────────────────────
Write-Step "Copying WinPE media from $MediaSource to $usbDrive ..."

$robocopyOut = "$env:TEMP\robocopy-usb-out.txt"
$robocopyErr = "$env:TEMP\robocopy-usb-err.txt"
$p = Start-Process -FilePath 'C:\Windows\System32\Robocopy.exe' `
    -ArgumentList "`"$MediaSource`" `"$usbDrive\`" /E /NP /NFL /NDL" `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $robocopyOut `
    -RedirectStandardError  $robocopyErr

# Robocopy exit codes: 0-7 = success (1 = files copied, 0 = no change)
if ($p.ExitCode -gt 7) {
    Write-Err "Robocopy failed (exit $($p.ExitCode)):"
    Get-Content $robocopyOut | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-OK "Files copied (robocopy exit $($p.ExitCode))."

# ─── Verify ───────────────────────────────────────────────────────────────────
Write-Step 'Verifying bootloader on USB...'
$bootloader = "$usbDrive\EFI\Boot\bootx64.efi"
if (Test-Path $bootloader) {
    $size = [math]::Round((Get-Item $bootloader).Length / 1KB, 0)
    Write-OK "bootx64.efi present ($size KB)"
} else {
    Write-Err "bootx64.efi NOT found at $bootloader — USB may not boot!"
    exit 1
}

$bootWim = "$usbDrive\sources\boot.wim"
if (Test-Path $bootWim) {
    $sizeMB = [math]::Round((Get-Item $bootWim).Length / 1MB, 0)
    Write-OK "boot.wim present ($sizeMB MB)"
} else {
    Write-Warn 'boot.wim not found at \sources\boot.wim — check media source.'
}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '   WinPE USB drive is ready!                 ' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''
Write-Host "  Drive : $usbDrive  (label: WINPE)"
Write-Host ''
Write-Host '  Boot the target machine from this USB in UEFI mode.' -ForegroundColor Yellow
Write-Host '  Secure Boot must be DISABLED in BIOS.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  On startup, press [T] within 5 seconds to open the diagnostic toolkit.' -ForegroundColor DarkGray
Write-Host '  Otherwise imaging will start automatically.' -ForegroundColor DarkGray
Write-Host ''
