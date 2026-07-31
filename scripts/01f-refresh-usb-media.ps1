#Requires -RunAsAdministrator
# 01f-refresh-usb-media.ps1
# Publish the USB-bootable WinPE media tree from the LIVE WDS boot image.
# RUN THIS ON pc-deploy, every time winpe-deploy-final.wim changes.
#
# WHY THIS EXISTS
# ---------------
# There are TWO delivery paths for the same WinPE, and they are fed differently:
#
#   PXE  ->  WDS serves C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim
#   USB  ->  01e-make-usb.ps1 copies a MEDIA TREE (EFI boot files + BCD + boot.wim)
#
# Injecting a driver into the boot image only updates the PXE path. The USB tree is
# a separate copy, so it silently keeps the OLD boot.wim until refreshed.
#
# Found 2026-07-21: after the Server 2025 / WDS migration, every media source
# 01e-make-usb.ps1 knew about had ceased to exist (winpemedia$, tftpd64$,
# C:\WinPE_amd64). The USB stick in circulation was built from media that was no
# longer on the server, so it lacked that day's Intel RST storage driver - and
# therefore could not see the disk on an RST-mode machine (LT-CNC / IdeaPad 81NY).
#
# The media tree needs the ADK's copype to lay down the correct USB BCD and EFI boot
# files; we then swap the stock ~324 MB boot.wim for our ~826 MB deploy image.

param(
    [string]$BootWim   = 'C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim',
    [string]$Workspace = 'C:\WinPE_amd64',
    [string]$Publish   = 'C:\deploy\winpe-media',
    [switch]$KeepWorkspace
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

Write-Host ''
Write-Host '  === Refresh USB WinPE media from the live WDS boot image ===' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $BootWim)) { Say "Boot image not found: $BootWim" Red; exit 1 }
$src = Get-Item $BootWim
Say ("Source boot image : {0} MB, modified {1}" -f [math]::Round($src.Length/1MB,0), $src.LastWriteTime) Green

$adk = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
$copype = "$adk\Windows Preinstallation Environment\copype.cmd"
if (-not (Test-Path $copype)) {
    Say 'ADK / WinPE add-on not installed - cannot lay down USB boot files.' Red
    Say 'Install the Windows ADK + WinPE Add-on, or run 01-setup-wds.ps1.' Yellow
    exit 1
}

# copype refuses to write into an existing directory
if (Test-Path $Workspace) { Say "Clearing $Workspace ..."; Remove-Item $Workspace -Recurse -Force }

Say 'Running copype (creates EFI boot files + USB-correct BCD)...'
$null = & cmd.exe /c "`"$adk\Deployment Tools\DandISetEnv.bat`" && `"$copype`" amd64 $Workspace" 2>&1
if (-not (Test-Path "$Workspace\media\sources\boot.wim")) { Say 'copype produced no media tree.' Red; exit 1 }
Say ("copype staged {0}" -f $Workspace) Green

# Swap the stock WinPE for ours (drivers, toolkit, deploy-boot all baked in)
Say 'Swapping in the deploy boot image...'
Copy-Item $BootWim "$Workspace\media\sources\boot.wim" -Force
Say ("boot.wim now {0} MB" -f [math]::Round((Get-Item "$Workspace\media\sources\boot.wim").Length/1MB,0)) Green

# Publish where 01e-make-usb.ps1 looks first: \\<server>\deploy$\winpe-media
if (Test-Path $Publish) { Remove-Item $Publish -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Publish | Out-Null
Copy-Item "$Workspace\media\*" $Publish -Recurse -Force
Say ("Published -> {0}" -f $Publish) Green

foreach ($f in 'EFI\Boot\bootx64.efi','boot\bcd','boot\boot.sdi','sources\boot.wim','bootmgr.efi') {
    if (Test-Path "$Publish\$f") { Say ("  [ok] {0}" -f $f) Green } else { Say ("  [!!] MISSING {0}" -f $f) Red }
}

if (-not $KeepWorkspace) { Remove-Item $Workspace -Recurse -Force -ErrorAction SilentlyContinue }

Say ''
Say ('boot.wim SHA256 = {0}' -f (Get-FileHash "$Publish\sources\boot.wim" -Algorithm SHA256).Hash) Cyan

Write-Host ''
Say 'Done. Now run 01e-make-usb.ps1 (from any workstation) to write a stick.' Cyan
Say 'USB and PXE are back in sync.' Cyan
Write-Host ''
Say 'ALWAYS HASH-VERIFY THE STICK AFTER WRITING.' Yellow
Say 'Learned 2026-07-21: a stick pulled before the write cache flushed produced a' Gray
Say 'boot.wim with the CORRECT SIZE but DIFFERENT CONTENT - i.e. a silently corrupt,' Gray
Say 'unbootable image that looks fine in Explorer. Copy with an explicit flush and' Gray
Say 'compare hashes before trusting the media:' Gray
Say '' Gray
Say '  $in=[IO.File]::OpenRead($src); $out=[IO.File]::Open($dst,"Create","Write","None")' Gray
Say '  $b=New-Object byte[] 4194304' Gray
Say '  while(($n=$in.Read($b,0,$b.Length)) -gt 0){ $out.Write($b,0,$n) }' Gray
Say '  $out.Flush($true); $out.Close(); $in.Close()   # $true = flush to the device' Gray
Say '  (Get-FileHash $dst -Algorithm SHA256).Hash -eq (Get-FileHash $src -Algorithm SHA256).Hash' Gray
Write-Host ''
