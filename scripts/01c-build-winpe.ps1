# 01c-build-winpe.ps1
# Builds a custom WinPE boot image and sets up the tftpd64 PXE/TFTP root.
#
# What this does:
#   1. Downloads and installs tftpd64 (PXE + TFTP server) if not present
#   2. Runs copype.cmd to create a WinPE workspace
#   3. Mounts boot.wim and injects optional components (PowerShell, DISM, etc.)
#   4. Copies startnet.cmd and deploy.ps1 into the WinPE image
#   5. Injects Juniper branding (background JPEG, deploy HTA, Poppins fonts)
#   6. Unmounts / commits the image
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
    [string]$WorkDir      = 'C:\WinPE_amd64',
    [string]$TftpRoot     = 'C:\tftpd64',
    # Folder containing the winpe\ sources (startnet.cmd, deploy.ps1)
    # Defaults to the directory containing this script's parent (repo root)
    [string]$RepoRoot     = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    # Juniper brand kit root — supplies the WinPE background generator and deploy HTA
    [string]$BrandKitRoot = 'C:\dev\juniper-brand-kit'
)

$ErrorActionPreference = 'Stop'

# Log everything (Write-Host, errors, output) to a transcript for remote visibility
$TranscriptPath = Join-Path (Split-Path $PSCommandPath) 'build.log'
Start-Transcript -Path $TranscriptPath -Force | Out-Null

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

    # Resolve latest portable zip URL from GitHub releases API
    $tftpdZip = "$env:TEMP\tftpd64_portable.zip"
    try {
        $rel      = Invoke-RestMethod 'https://api.github.com/repos/PJO2/tftpd64/releases/latest' -UseBasicParsing
        $asset    = $rel.assets | Where-Object { $_.name -match 'tftpd64_portable' } | Select-Object -First 1
        $tftpdUrl = $asset.browser_download_url
        if (-not $tftpdUrl) { throw "No tftpd64_portable asset found in latest release" }
    } catch {
        # Fallback to known-good v4.74 if the API call fails
        $tftpdUrl = 'https://github.com/PJO2/tftpd64/releases/download/v4.74/tftpd64_portable_v4.74.zip'
    }

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
    Write-Host "  Cleaning up existing workspace at $WorkDir..."
    # Discard any mounted WIM images first (a previous partial run may have left one mounted)
    $mountDir = "$WorkDir\mount"
    if (Test-Path $mountDir) {
        Write-Host "  Discarding any mounted WIM at $mountDir..."
        # Use & directly (not Start-Process) so DISM runs in the same session context
        & $dismExe /Unmount-WIM /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
        Write-Host "    Unmount complete."
    }
    # Also clean up any DISM orphaned mounts pointing at this workspace
    & $dismExe /Cleanup-Mountpoints 2>&1 | Out-Null
    Write-Host "  Cleanup-Mountpoints complete."
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $WorkDir) {
        Write-Host "  WARN: Could not fully remove $WorkDir — some files may still be locked." -ForegroundColor Yellow
        Write-Host "  Rebooting pc-deploy and re-running this script may be required."
    } else {
        Write-Host "  Workspace removed." -ForegroundColor Green
    }
}

# copype.cmd requires the full ADK environment (WinPERoot, OSCDImgRoot, PATH additions).
# Source DandISetEnv.bat in the same cmd session so all vars are available.
$dandI = "$adkRoot\Deployment Tools\DandISetEnv.bat"

$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
$p = Start-Process 'cmd.exe' `
     -ArgumentList "/c `"call `"$dandI`" && `"$copype`" amd64 `"$WorkDir`"`"" `
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

# Use the DISM PowerShell module so that Mount + Add-Package + Dismount all share
# the same process session.  Start-Process dism.exe creates isolated child processes
# that cannot access each other's DISM sessions (HRESULT=C1510115).
Import-Module Dism -ErrorAction Stop

$wimFile  = "$WorkDir\media\sources\boot.wim"
$mountDir = "$WorkDir\mount"

New-Item -Path $mountDir -ItemType Directory -Force | Out-Null

try {
    Mount-WindowsImage -ImagePath $wimFile -Index 1 -Path $mountDir -ErrorAction Stop | Out-Null
} catch {
    Write-Host "  DISM mount failed: $_" -ForegroundColor Red
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
    try {
        Add-WindowsPackage -Path $mountDir -PackagePath $ocCab -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "    WARN: $oc add-package failed: $_" -ForegroundColor Yellow
    }

    if (Test-Path $langCab) {
        try {
            Add-WindowsPackage -Path $mountDir -PackagePath $langCab -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "    WARN: $oc lang pack failed: $_" -ForegroundColor Yellow
        }
    }
}
Write-Host '  Optional components added.' -ForegroundColor Green

# ─── Step 5: Inject startnet.cmd and deploy-boot.ps1 ─────────────────────────
# deploy-boot.ps1 is the minimal bootstrap baked into the WIM.
# The full deploy logic lives on the share at deploy$\scripts\deploy.ps1
# so it can be updated without rebuilding the WIM.
Write-Host ''
Write-Host '==> Step 5: Inject startnet.cmd and deploy-boot.ps1' -ForegroundColor Cyan

$winpeSourceDir = ''
# Look for winpe\ next to this script, then in common repo locations
$candidates = @(
    (Join-Path $PSScriptRoot '..\winpe'),
    'C:\dev\pc-imaging-server\winpe'
)
if ($RepoRoot) { $candidates += (Join-Path $RepoRoot 'winpe') }
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'deploy-boot.ps1')) { $winpeSourceDir = (Resolve-Path $c).Path; break }
}

if (-not $winpeSourceDir) {
    Write-Host '  ERROR: Cannot find winpe\deploy-boot.ps1. Copy this repo to pc-deploy and re-run,' -ForegroundColor Red
    Write-Host '         or pass -RepoRoot to point at the checkout.'
    # Unmount without commit so we don't corrupt the WIM
    & $dismExe /Unmount-WIM /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
    exit 1
}

Copy-Item (Join-Path $winpeSourceDir 'startnet.cmd')    "$mountDir\Windows\System32\startnet.cmd"    -Force
Copy-Item (Join-Path $winpeSourceDir 'deploy-boot.ps1') "$mountDir\Windows\System32\deploy-boot.ps1" -Force
Write-Host "  Injected startnet.cmd and deploy-boot.ps1 from $winpeSourceDir" -ForegroundColor Green

# Inject toolkit.ps1 — network diagnostic tool (press T at boot to launch)
$toolkitSrc = Join-Path $winpeSourceDir 'toolkit.ps1'
if (Test-Path $toolkitSrc) {
    Copy-Item $toolkitSrc "$mountDir\Windows\System32\toolkit.ps1" -Force
    Write-Host "  Injected toolkit.ps1" -ForegroundColor Green
} else {
    Write-Host "  WARN: toolkit.ps1 not found in $winpeSourceDir — skipping." -ForegroundColor Yellow
}

# ─── Step 5b: Inject Juniper branding ─────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 5b: Inject Juniper branding' -ForegroundColor Cyan

$brandWinPE = Join-Path $BrandKitRoot 'winpe'
if (-not (Test-Path $BrandKitRoot)) {
    Write-Host "  WARN: Brand kit not found at $BrandKitRoot — skipping branding." -ForegroundColor Yellow
} else {
    # Generate the branded background JPEG
    $bgScript = Join-Path $brandWinPE 'build-winpe-bg.ps1'
    $bgOut    = Join-Path $brandWinPE 'juniper-winpe-bg.jpg'
    if (Test-Path $bgScript) {
        Write-Host '  Generating WinPE background...'
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        $p = Start-Process 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$bgScript`" -OutFile `"$bgOut`"" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) {
            Write-Host "    WARN: Background generation failed (exit $($p.ExitCode)). $err" -ForegroundColor Yellow
        } else {
            Write-Host '    OK' -ForegroundColor Green
        }
    }

    # Copy background into WIM as winpe.jpg (WinPE desktop background)
    if (Test-Path $bgOut) {
        Copy-Item $bgOut "$mountDir\Windows\System32\winpe.jpg" -Force
        Write-Host '  Copied winpe.jpg into WIM.' -ForegroundColor Green
    }

    # Copy branded deploy HTA
    $htaSrc = Join-Path $brandWinPE 'deploy-ui.hta'
    if (Test-Path $htaSrc) {
        Copy-Item $htaSrc "$mountDir\Windows\System32\deploy-ui.hta" -Force
        Write-Host '  Copied deploy-ui.hta into WIM.' -ForegroundColor Green
    }

    # Copy Poppins fonts into WIM (needed by HTA for on-brand text rendering)
    $fontsDir = Join-Path $BrandKitRoot 'fonts'
    if (Test-Path $fontsDir) {
        New-Item "$mountDir\Windows\Fonts" -ItemType Directory -Force | Out-Null
        Get-ChildItem $fontsDir -Filter 'Poppins-*.ttf' | ForEach-Object {
            Copy-Item $_.FullName "$mountDir\Windows\Fonts\$($_.Name)" -Force
        }
        Write-Host '  Copied Poppins fonts into WIM.' -ForegroundColor Green
    }
}

# ─── Step 6: Unmount and commit ────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Step 6: Unmount and commit boot.wim' -ForegroundColor Cyan

try {
    Dismount-WindowsImage -Path $mountDir -Save -ErrorAction Stop | Out-Null
} catch {
    Write-Host "  DISM unmount/commit failed: $_" -ForegroundColor Red
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
BootFile=EFI\Boot\bootx64.efi
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

# tftpd64.exe is a GUI app — it cannot self-register as a service.
# Use NSSM (already present at C:\nssm\nssm.exe for the inventory service) to wrap it.
$nssmBin  = 'C:\nssm\nssm.exe'
$iniPath  = "$TftpRoot\tftpd64.ini"

$tftpdSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
if ($tftpdSvc) {
    Write-Host '  Service already registered — restarting.' -ForegroundColor Green
    Restart-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
} else {
    if (-not (Test-Path $nssmBin)) {
        Write-Host "  ERROR: NSSM not found at $nssmBin. Install NSSM and re-run." -ForegroundColor Red
    } else {
        & $nssmBin install tftpd64 $tftpdExe "-z `"$iniPath`""
        & $nssmBin set tftpd64 DisplayName 'tftpd64 PXE/TFTP Server'
        & $nssmBin set tftpd64 Start SERVICE_AUTO_START
        & $nssmBin set tftpd64 AppStdout "$TftpRoot\tftpd64.log"
        & $nssmBin set tftpd64 AppStderr "$TftpRoot\tftpd64-err.log"
        Write-Host '  Service installed via NSSM.' -ForegroundColor Green
        Start-Service tftpd64 -ErrorAction SilentlyContinue
    }
}

$tftpdSvc = Get-Service -Name 'tftpd64' -ErrorAction SilentlyContinue
if ($tftpdSvc -and $tftpdSvc.Status -eq 'Running') {
    Write-Host '  tftpd64 service is running.' -ForegroundColor Green
} else {
    Write-Host "  WARN: tftpd64 service not running (state: $($tftpdSvc.Status)). Start manually: Start-Service tftpd64" -ForegroundColor Yellow
}

# ─── Step 10: Expose winpemedia$ share for USB drive creation ─────────────────
# 01e-make-usb.ps1 needs the WinPE workspace BCD (not the tftpd64 BCD, which is
# PXE-only) to create a USB-bootable drive.  Expose C:\WinPE_amd64\media as
# winpemedia$ so ENG-2 can pull the correct BCD at USB-write time.
Write-Host ''
Write-Host '==> Step 10: Expose winpemedia$ share' -ForegroundColor Cyan
$wmShare = Get-SmbShare -Name 'winpemedia$' -ErrorAction SilentlyContinue
if ($wmShare) { Remove-SmbShare -Name 'winpemedia$' -Force }
New-SmbShare -Name 'winpemedia$' -Path "$WorkDir\media" `
             -FullAccess 'SYSTEM','Administrators' | Out-Null
Grant-SmbShareAccess -Name 'winpemedia$' -AccountName 'Everyone' `
                     -AccessRight Read -Force | Out-Null
Write-Host "  winpemedia$ -> $WorkDir\media (Everyone:Read)" -ForegroundColor Green

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

Stop-Transcript | Out-Null
