# 01c-build-winpe.ps1
# Builds a custom WinPE boot image and sets up the tftpd64 PXE/TFTP root.
#
# What this does:
#   1. Downloads and installs tftpd64 (PXE + TFTP server) if not present
#   2. Runs copype.cmd to create a WinPE workspace
#   3. Mounts boot.wim and injects optional components (PowerShell, DISM, etc.)
#   4. Copies startnet.cmd and deploy.ps1 into the WinPE image
#   5. Unmounts / commits the image
#   6. Copies the bootable media tree into C:\tftpd64\
#   7. Writes a tftpd64.ini config (proxy DHCP mode)
#   8. Installs and starts the tftpd64 service
#
# PREREQUISITES:
#   - ADK + WinPE Add-on installed (run 01-setup-wds.ps1 first)
#   - startnet.cmd and deploy.ps1 present in this repo's winpe\ folder
#     (copy or run from \\<ENG-2>\...\pc-imaging-server, or clone to pc-deploy)
#   - Run as Administrator on pc-deploy
#
# USAGE: .\01c-build-winpe.ps1
#        .\01c-build-winpe.ps1 -WorkDir C:\WinPE_work -TftpRoot C:\tftpd64

param(
    [string]$WorkDir  = 'C:\WinPE_amd64',
    [string]$TftpRoot = 'C:\tftpd64',
    # Folder containing the winpe\ sources (startnet.cmd, deploy.ps1)
    # Defaults to the directory containing this script's parent (repo root)
    [string]$RepoRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'

$adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
$copype   = "$adkRoot\Windows Preinstallation Environment\copype.cmd"
$dismExe  = "$adkRoot\Deployment Tools\amd64\DISM\dism.exe"
$ocRoot   = "$adkRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"

Write-Host '==> WinPE Build + TFTP Setup' -ForegroundColor Cyan
Write-Host ''

# ─── Validate ADK ──────────────────────────────────────────────────────────────
if (-not (Test-Path $copype)) {
    Write-Host "ERROR: copype.cmd not found at $copype" -ForegroundColor Red
    Write-Host 'Make sure ADK + WinPE Add-on are installed (run 01-setup-wds.ps1).'
    exit 1
}
if (-not (Test-Path $dismExe)) {
    Write-Host "ERROR: DISM not found at $dismExe" -ForegroundColor Red
    exit 1
}
Write-Host "  ADK root   : $adkRoot" -ForegroundColor DarkGray
Write-Host "  WinPE work : $WorkDir"
Write-Host "  TFTP root  : $TftpRoot"
Write-Host ''

# ─── Step 1: tftpd64 ───────────────────────────────────────────────────────────
Write-Host '==> Step 1: tftpd64' -ForegroundColor Cyan

$tftpdExe = "$TftpRoot\tftpd64.exe"
$tftpdSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue

if ($tftpdSvc) {
    Write-Host '  tftpd64 service already installed.' -ForegroundColor Green
} elseif (Test-Path $tftpdExe) {
    Write-Host "  tftpd64.exe already at $tftpdExe." -ForegroundColor Green
} else {
    New-Item -Path $TftpRoot -ItemType Directory -Force | Out-Null

    # Official download from BitBucket. If this URL returns 404, go to:
    # https://bitbucket.org/phjounin/tftpd64/downloads/ and grab the latest zip.
    $tftpdUrl = 'https://bitbucket.org/phjounin/tftpd64/downloads/tftpd64_4.64.zip'
    $tftpdZip = "$env:TEMP\tftpd64.zip"

    Write-Host "  Downloading tftpd64 from $tftpdUrl..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($tftpdUrl, $tftpdZip)
        Write-Host '  Download complete.' -ForegroundColor Green
    } catch {
        Write-Host "  Download failed: $_" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Manual download instructions:' -ForegroundColor Yellow
        Write-Host '    1. Go to https://bitbucket.org/phjounin/tftpd64/downloads/'
        Write-Host '    2. Download the latest tftpd64_*.zip'
        Write-Host "    3. Extract the contents to $TftpRoot"
        Write-Host '    4. Re-run this script (tftpd64 check will be skipped).'
        exit 1
    }

    Write-Host "  Extracting to $TftpRoot..."
    Expand-Archive -Path $tftpdZip -DestinationPath $TftpRoot -Force
    Remove-Item $tftpdZip -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $tftpdExe)) {
        # The zip might have a subdirectory — flatten it
        $inner = Get-ChildItem $TftpRoot -Recurse -Filter 'tftpd64.exe' | Select-Object -First 1
        if ($inner) {
            Get-ChildItem $inner.DirectoryName | Move-Item -Destination $TftpRoot -Force
            Remove-Item $inner.DirectoryName -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $tftpdExe)) {
        Write-Host "  ERROR: tftpd64.exe not found in $TftpRoot after extraction." -ForegroundColor Red
        exit 1
    }
    Write-Host "  tftpd64 extracted to $TftpRoot." -ForegroundColor Green
}

# ─── Step 2: copype ────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 2: Create WinPE workspace (copype)' -ForegroundColor Cyan

if (Test-Path $WorkDir) {
    Write-Host "  Removing existing workspace at $WorkDir..."
    Remove-Item $WorkDir -Recurse -Force
}

$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
$p = Start-Process 'cmd.exe' `
     -ArgumentList "/c `"$copype`" amd64 `"$WorkDir`"" `
     -NoNewWindow -Wait -PassThru `
     -RedirectStandardOutput $o -RedirectStandardError $e
$out = Get-Content $o -Raw; $err = Get-Content $e -Raw
Remove-Item $o,$e -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) {
    Write-Host "  copype failed (exit $($p.ExitCode)):" -ForegroundColor Red
    Write-Host $out; Write-Host $err
    exit 1
}
Write-Host "  WinPE workspace created at $WorkDir." -ForegroundColor Green

# ─── Step 3: Mount boot.wim ────────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 3: Mount boot.wim' -ForegroundColor Cyan

$wimFile  = "$WorkDir\media\sources\boot.wim"
$mountDir = "$WorkDir\mount"

New-Item -Path $mountDir -ItemType Directory -Force | Out-Null

$p = Start-Process $dismExe `
     -ArgumentList "/Mount-Image /ImageFile:`"$wimFile`" /Index:1 /MountDir:`"$mountDir`"" `
     -NoNewWindow -Wait -PassThru
if ($p.ExitCode -ne 0) {
    Write-Host "  DISM mount failed (exit $($p.ExitCode))" -ForegroundColor Red
    exit 1
}
Write-Host '  boot.wim mounted.' -ForegroundColor Green

# ─── Step 4: Add optional components ───────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 4: Add optional components' -ForegroundColor Cyan

$ocs = @(
    'WinPE-WMI',
    'WinPE-NetFX',
    'WinPE-Scripting',
    'WinPE-PowerShell',
    'WinPE-DismCmdlets',
    'WinPE-StorageWMI',
    'WinPE-EnhancedStorage'
)

foreach ($oc in $ocs) {
    $ocCab    = "$ocRoot\$oc.cab"
    $langCab  = "$ocRoot\en-us\${oc}_en-us.cab"

    if (-not (Test-Path $ocCab)) {
        Write-Host "  WARN: $oc.cab not found, skipping." -ForegroundColor Yellow
        continue
    }
    Write-Host "  Adding $oc..."
    $p = Start-Process $dismExe `
         -ArgumentList "/Image:`"$mountDir`" /Add-Package /PackagePath:`"$ocCab`"" `
         -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Host "    WARN: exit $($p.ExitCode)" -ForegroundColor Yellow }

    if (Test-Path $langCab) {
        $p = Start-Process $dismExe `
             -ArgumentList "/Image:`"$mountDir`" /Add-Package /PackagePath:`"$langCab`"" `
             -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "    WARN: lang pack exit $($p.ExitCode)" -ForegroundColor Yellow }
    }
}
Write-Host '  Optional components added.' -ForegroundColor Green

# ─── Step 5: Inject startnet.cmd and deploy.ps1 ────────────────────────────────
Write-Host ''
Write-Host '==> Step 5: Inject startnet.cmd and deploy.ps1' -ForegroundColor Cyan

$winpeSourceDir = ''
# Look for winpe\ next to this script, then in common repo locations
$candidates = @(
    (Join-Path $PSScriptRoot '..\winpe'),
    (Join-Path $RepoRoot 'winpe'),
    'C:\dev\pc-imaging-server\winpe'
)
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'deploy.ps1')) { $winpeSourceDir = (Resolve-Path $c).Path; break }
}

if (-not $winpeSourceDir) {
    Write-Host '  ERROR: Cannot find winpe\deploy.ps1. Copy this repo to pc-deploy and re-run,' -ForegroundColor Red
    Write-Host '         or pass -RepoRoot to point at the checkout.'
    # Unmount without commit so we don't corrupt the WIM
    Start-Process $dismExe -ArgumentList "/Unmount-Image /MountDir:`"$mountDir`" /Discard" -NoNewWindow -Wait
    exit 1
}

Copy-Item (Join-Path $winpeSourceDir 'startnet.cmd') "$mountDir\Windows\System32\startnet.cmd" -Force
Copy-Item (Join-Path $winpeSourceDir 'deploy.ps1')   "$mountDir\Windows\System32\deploy.ps1"   -Force
Write-Host "  Injected startnet.cmd and deploy.ps1 from $winpeSourceDir" -ForegroundColor Green

# ─── Step 6: Unmount and commit ────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 6: Unmount and commit boot.wim' -ForegroundColor Cyan

$p = Start-Process $dismExe `
     -ArgumentList "/Unmount-Image /MountDir:`"$mountDir`" /Commit" `
     -NoNewWindow -Wait -PassThru
if ($p.ExitCode -ne 0) {
    Write-Host "  DISM unmount failed (exit $($p.ExitCode))" -ForegroundColor Red
    exit 1
}
Write-Host '  boot.wim committed.' -ForegroundColor Green

# ─── Step 7: Populate TFTP root ────────────────────────────────────────────────
Write-Host ''
Write-Host "==> Step 7: Populate TFTP root ($TftpRoot)" -ForegroundColor Cyan

# Preserve tftpd64.exe and any existing ini — copy only WinPE media
$tftpdExeBackup = $null
if (Test-Path $tftpdExe) { $tftpdExeBackup = $tftpdExe }

# Copy boot media tree (boot\, efi\, sources\, etc.)
$mediaItems = Get-ChildItem "$WorkDir\media" | Where-Object { $_.Name -ne 'sources' }
foreach ($item in $mediaItems) {
    $dest = Join-Path $TftpRoot $item.Name
    if ($item.PSIsContainer) {
        Copy-Item $item.FullName $dest -Recurse -Force
    } else {
        Copy-Item $item.FullName $dest -Force
    }
}
# Copy sources\ separately (large; only boot.wim matters for PXE)
New-Item "$TftpRoot\sources" -ItemType Directory -Force | Out-Null
Copy-Item "$WorkDir\media\sources\boot.wim" "$TftpRoot\sources\boot.wim" -Force

Write-Host "  Boot media copied to $TftpRoot." -ForegroundColor Green

# ─── Step 8: Write tftpd64.ini ─────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 8: Write tftpd64.ini' -ForegroundColor Cyan

# tftpd64 uses a portable INI. We configure it for proxy-DHCP mode so it
# works alongside the Ubiquiti router's built-in DHCP server.
$ini = @"
[TFTP]
TFTPServer=192.168.5.141
TFTP_Port=69
TFTPBaseDirectory=$TftpRoot
AnonymousAccess=1
Syslog=0
SyslogLevel=0

[PXE]
PXE_Port=4011
BootFile=boot\bootmgfw.efi
ProxyDHCP=1

[DHCP]
DHCPType=PROXY
"@

$iniPath = "$TftpRoot\tftpd64.ini"
$ini | Set-Content $iniPath -Encoding ASCII
Write-Host "  tftpd64.ini written to $iniPath." -ForegroundColor Green

# ─── Step 9: Install tftpd64 as a service ──────────────────────────────────────
Write-Host ''
Write-Host '==> Step 9: Install tftpd64 service' -ForegroundColor Cyan

$tftpdSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
if ($tftpdSvc) {
    Write-Host '  Service already registered.' -ForegroundColor Green
} else {
    $svBin = "$TftpRoot\tftpd64_svc.exe"
    if (-not (Test-Path $svBin)) { $svBin = $tftpdExe }   # some builds ship a single exe

    $p = Start-Process $svBin -ArgumentList '--service install' -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "  WARN: Service install returned $($p.ExitCode). Try starting tftpd64 manually." -ForegroundColor Yellow
    } else {
        Write-Host '  Service installed.' -ForegroundColor Green
    }
}

# Start / restart
$tftpdSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
if ($tftpdSvc) {
    try {
        Restart-Service -Name 'tftpd64' -ErrorAction Stop
        Write-Host '  tftpd64 service started.' -ForegroundColor Green
    } catch {
        Write-Host "  WARN: Could not start service: $_" -ForegroundColor Yellow
        Write-Host "  Start it manually: Start-Service tftpd64" -ForegroundColor Yellow
    }
}

# ─── Done ──────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== WinPE Build Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host "  1. Run 01d-setup-deploy-share.ps1 to create the deploy$ share on this machine."
Write-Host ''
Write-Host '  2. Copy OS images to C:\deploy\images\ :'
Write-Host '       Mount Windows ISO, then:'
Write-Host '         dism /Get-WimInfo /WimFile:D:\sources\install.wim   (check Pro index)'
Write-Host '         copy D:\sources\install.wim C:\deploy\images\win11.wim'
Write-Host '         copy D:\sources\install.wim C:\deploy\images\win10.wim  (if needed)'
Write-Host ''
Write-Host '  3. Verify Ubiquiti DHCP options:'
Write-Host '       Option 66 (TFTP server) = 192.168.5.141'
Write-Host '       Option 67 (boot file)   = boot\bootmgfw.efi  (or check UniFi Network Boot)'
Write-Host ''
Write-Host '  4. PXE-boot a test machine — it should reach the Juniper deploy menu.'
