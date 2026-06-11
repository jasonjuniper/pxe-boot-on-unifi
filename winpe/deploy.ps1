# deploy.ps1 — Juniper Design WinPE Deployment Script
#
# Runs inside WinPE on the target machine (launched by startnet.cmd).
# Prompts for OS selection and computer name, partitions disk 0,
# applies the Windows image via DISM, injects unattend.xml with the
# chosen computer name, sets up the boot sector, and reboots.
#
# DEPLOYMENT SHARE: \\192.168.5.141\deploy$ (no credentials — share is
# open read-only to Everyone; no secrets are stored there)
#
# SHARE LAYOUT (C:\deploy on pc-deploy):
#   images\win11.wim         Windows 11 Pro install.wim (from ISO)
#   images\win10.wim         Windows 10 Pro install.wim (from ISO)
#   unattend\unattend-win11.xml
#   unattend\unattend-win10.xml
#   scripts\03-07*.ps1       Post-install scripts (run after first logon)
#
# WIM INDEXES: Run  dism /Get-WimInfo /WimFile:<share>\images\win11.wim
# to verify the Pro index on your specific ISO. Default is 6 (standard
# multi-edition ISO). Single-edition Pro ISOs use index 1.

$ErrorActionPreference = 'Stop'

$DeployServer = '192.168.5.141'   # pc-deploy — use IP, DNS may not work in WinPE
$DeployShare  = "\\$DeployServer\deploy$"

$OsOptions = @{
    '1' = @{
        Label    = 'Windows 11 Pro'
        WimFile  = 'images\win11.wim'
        WimIndex = 6          # verify with: dism /Get-WimInfo /WimFile:...
        Unattend = 'unattend\unattend-win11.xml'
    }
    '2' = @{
        Label    = 'Windows 10 Pro'
        WimFile  = 'images\win10.wim'
        WimIndex = 6
        Unattend = 'unattend\unattend-win10.xml'
    }
}

# ─── Helpers ────────────────────────────────────────────────────────────────

function Get-NormalizedModelKey([string]$Manufacturer, [string]$Model) {
    # Strip leading manufacturer name if WMI duplicates it (e.g. "HP HP EliteBook")
    $mdl = $Model.Trim()
    $mfr = $Manufacturer.Trim()
    if ($mdl -imatch "^$([regex]::Escape($mfr))\s+") {
        $mdl = $mdl.Substring($mfr.Length).TrimStart()
    }
    # Normalize to lowercase kebab-case
    $key = "$mfr-$mdl" -replace '[^A-Za-z0-9]', '-' -replace '-{2,}', '-' -replace '^-|-$', ''
    return $key.ToLower()
}

function Invoke-DriverInjection([string]$DeployShare, [string]$Manufacturer, [string]$Model) {
    $manifestPath = "$DeployShare\drivers\manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Host '  INFO: No driver manifest at deploy$\drivers\manifest.json — skipping.' -ForegroundColor DarkGray
        return
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $normalKey = Get-NormalizedModelKey -Manufacturer $Manufacturer -Model $Model

    # Match by wmiModels list first (most reliable), then by normalized key
    $matched = $null
    foreach ($prop in $manifest.models.PSObject.Properties) {
        $entry = $prop.Value
        if ($entry.wmiModels -contains $Model) { $matched = $entry; break }
    }
    if (-not $matched) {
        foreach ($prop in $manifest.models.PSObject.Properties) {
            if ($prop.Name -eq $normalKey) { $matched = $prop.Value; break }
        }
    }

    if (-not $matched) {
        Write-Host "  WARN: No driver pack in manifest for '$Model' (key: $normalKey)" -ForegroundColor Yellow
        Write-Host '        Windows generic/inbox drivers will be used.' -ForegroundColor Yellow
        Write-Host '        Add this model to drivers\manifest.json and run 09-update-driver-warehouse.ps1.' -ForegroundColor Yellow
        return
    }

    $driverSrc = "$DeployShare\drivers\$($matched.driverPath)"
    if (-not (Test-Path $driverSrc)) {
        Write-Host "  WARN: Driver pack listed in manifest but folder not found: $driverSrc" -ForegroundColor Yellow
        Write-Host '        Run 09-update-driver-warehouse.ps1 on pc-deploy to populate missing driver packs.' -ForegroundColor Yellow
        return
    }

    $infCount = (Get-ChildItem $driverSrc -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    Write-Host "  Injecting driver pack for $Model ($infCount .inf files)..." -ForegroundColor Cyan
    $p = Start-Process dism -ArgumentList "/Image:C:\ /Add-Driver /Driver:`"$driverSrc`" /Recurse /ForceUnsigned" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) {
        Write-Host '  Drivers injected successfully.' -ForegroundColor Green
    } else {
        Write-Host "  WARN: DISM driver injection returned exit $($p.ExitCode) — some drivers may need post-install." -ForegroundColor Yellow
    }
}

function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host '   Juniper Design  -  PC Deployment System  ' -ForegroundColor Cyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Wait-ForNetwork {
    Write-Host 'Waiting for network...' -ForegroundColor Yellow
    for ($i = 1; $i -le 30; $i++) {
        if (Test-Connection $DeployServer -Count 1 -Quiet 2>$null) {
            Write-Host "  Connected to $DeployServer." -ForegroundColor Green
            return $true
        }
        Write-Host "  [$i/30] Retrying in 2 s..."
        Start-Sleep 2
    }
    return $false
}

# ─── Start ──────────────────────────────────────────────────────────────────

Write-Banner

# Network
if (-not (Wait-ForNetwork)) {
    Write-Host ''
    Write-Host "  Cannot reach $DeployServer. Check network cable / switch." -ForegroundColor Red
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# Map share
try { net use $DeployShare /persistent:no *>$null } catch {}
if (-not (Test-Path $DeployShare)) {
    Write-Host "  Cannot reach $DeployShare" -ForegroundColor Red
    Write-Host '  Verify deploy$ share is accessible from WinPE (Everyone:Read).' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# ─── Detect Hardware Model ───────────────────────────────────────────────────

$hwWmiCS  = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
$hwWmiBios = Get-WmiObject -Class Win32_BIOS -ErrorAction SilentlyContinue
$hwMfr    = if ($hwWmiCS)   { $hwWmiCS.Manufacturer.Trim() } else { 'Unknown' }
$hwModel  = if ($hwWmiCS)   { $hwWmiCS.Model.Trim()        } else { 'Unknown' }
$hwSerial = if ($hwWmiBios) { $hwWmiBios.SerialNumber.Trim() } else { 'Unknown' }

Write-Host '  ── Hardware Detected ───────────────────────────' -ForegroundColor DarkCyan
Write-Host "    Manufacturer : $hwMfr"
Write-Host "    Model        : $hwModel"
Write-Host "    Serial       : $hwSerial"

# Check if a driver pack exists for this model
$manifestPath = "$DeployShare\drivers\manifest.json"
if (Test-Path $manifestPath) {
    $manifest  = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $driverHit = $false
    foreach ($prop in $manifest.models.PSObject.Properties) {
        if ($prop.Value.wmiModels -contains $hwModel) { $driverHit = $true; break }
    }
    if (-not $driverHit) {
        $nk = Get-NormalizedModelKey -Manufacturer $hwMfr -Model $hwModel
        foreach ($prop in $manifest.models.PSObject.Properties) {
            if ($prop.Name -eq $nk) { $driverHit = $true; break }
        }
    }
    if ($driverHit) {
        Write-Host '    Drivers      : FOUND in warehouse' -ForegroundColor Green
    } else {
        Write-Host '    Drivers      : NOT in warehouse — inbox drivers only' -ForegroundColor Yellow
    }
} else {
    Write-Host '    Drivers      : no manifest found' -ForegroundColor DarkGray
}
Write-Host ''

# ─── OS Selection ────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Select OS to deploy:' -ForegroundColor Cyan
foreach ($k in ($OsOptions.Keys | Sort-Object)) {
    Write-Host "    [$k] $($OsOptions[$k].Label)"
}
Write-Host ''

$osKey = ''
while ($osKey -notin $OsOptions.Keys) { $osKey = Read-Host '  Choice' }
$os = $OsOptions[$osKey]

$wimPath = Join-Path $DeployShare $os.WimFile
if (-not (Test-Path $wimPath)) {
    Write-Host ''
    Write-Host "  WIM not found: $wimPath" -ForegroundColor Red
    Write-Host ''
    Write-Host '  To prepare images on pc-deploy:' -ForegroundColor Yellow
    Write-Host '    Mount ISO, then:'
    Write-Host '      dism /Get-WimInfo /WimFile:D:\sources\install.wim'
    Write-Host '      copy D:\sources\install.wim C:\deploy\images\win11.wim'
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# ─── Computer Name ───────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Computer name:' -ForegroundColor Cyan
Write-Host '    1-15 chars, letters / numbers / hyphens (e.g. JUNIPER-WS-01)'
Write-Host ''

$computerName = ''
while ($true) {
    $computerName = (Read-Host '  Name').Trim().ToUpper()
    # NetBIOS: 1-15 chars, no leading/trailing hyphen, valid chars only
    if ($computerName -match '^[A-Z0-9]([A-Z0-9\-]{0,13}[A-Z0-9])?$' -and
        $computerName.Length -ge 1 -and $computerName.Length -le 15) { break }
    Write-Host '    Invalid. Use letters, numbers, hyphens. Max 15 chars.' -ForegroundColor Yellow
}

# ─── Disk 0 Info + Confirmation ──────────────────────────────────────────────

Write-Host ''
Write-Host '  ── Target: Disk 0 ──────────────────────────────' -ForegroundColor Cyan
$disk = Get-Disk | Where-Object Number -eq 0 | Select-Object -First 1
if ($disk) {
    Write-Host "    Model : $($disk.FriendlyName)"
    Write-Host "    Size  : $([math]::Round($disk.Size/1GB, 0)) GB"
    Write-Host "    Style : $($disk.PartitionStyle)"
}

Write-Host ''
Write-Host "    OS    : $($os.Label)"
Write-Host "    Name  : $computerName"
Write-Host ''
Write-Host '  !! Disk 0 will be COMPLETELY WIPED !!' -ForegroundColor Red
Write-Host ''

$confirm = Read-Host '  Type YES to proceed, anything else to abort'
if ($confirm -ne 'YES') {
    Write-Host '  Aborted.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# ─── Partition Disk 0 (GPT / UEFI) ──────────────────────────────────────────

Write-Host ''
Write-Host '  Partitioning disk 0 (GPT/UEFI)...' -ForegroundColor Cyan

$dpTxt = @'
select disk 0
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
exit
'@

$dpFile = "$env:TEMP\juniper_diskpart.txt"
$dpTxt | Set-Content $dpFile -Encoding ASCII
$p = Start-Process diskpart -ArgumentList "/s `"$dpFile`"" -Wait -PassThru -NoNewWindow
Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) {
    Write-Host "  diskpart failed (exit $($p.ExitCode))" -ForegroundColor Red
    Read-Host '  Press Enter to exit'
    exit
}
Write-Host '  Partitioned: S: (EFI), C: (Windows).' -ForegroundColor Green

# ─── Apply WIM ───────────────────────────────────────────────────────────────

Write-Host ''
Write-Host "  Applying $($os.Label) (index $($os.WimIndex))..." -ForegroundColor Cyan
Write-Host '  This takes 10-20 minutes depending on disk speed.'
Write-Host ''

$p = Start-Process dism -ArgumentList "/Apply-Image /ImageFile:`"$wimPath`" /Index:$($os.WimIndex) /ApplyDir:C:\" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  DISM apply failed (exit $($p.ExitCode))" -ForegroundColor Red
    Read-Host '  Press Enter to exit'
    exit
}
Write-Host '  Image applied.' -ForegroundColor Green

# ─── Inject Drivers (offline) ────────────────────────────────────────────────

Write-Host ''
Write-Host '  Injecting hardware drivers...' -ForegroundColor Cyan
Invoke-DriverInjection -DeployShare $DeployShare -Manufacturer $hwMfr -Model $hwModel

# ─── Inject unattend.xml with computer name ───────────────────────────────────

Write-Host ''
Write-Host '  Writing unattend.xml...' -ForegroundColor Cyan

$unattendSrc = Join-Path $DeployShare $os.Unattend
if (-not (Test-Path $unattendSrc)) {
    Write-Host "  WARN: Unattend not found at $unattendSrc — skipping." -ForegroundColor Yellow
} else {
    New-Item 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null
    $xml = Get-Content $unattendSrc -Raw
    # Replace the wildcard ComputerName with the chosen name
    $xml = $xml -replace '<ComputerName>\*</ComputerName>', "<ComputerName>$computerName</ComputerName>"
    $xml | Set-Content 'C:\Windows\Panther\unattend.xml' -Encoding UTF8
    Write-Host "  unattend.xml written (ComputerName=$computerName)." -ForegroundColor Green
}

# ─── Boot sector ─────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Configuring UEFI boot...' -ForegroundColor Cyan
$p = Start-Process bcdboot -ArgumentList 'C:\Windows /s S: /f UEFI' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  bcdboot failed (exit $($p.ExitCode))" -ForegroundColor Red
    Read-Host '  Press Enter to exit'
    exit
}
Write-Host '  Boot sector configured.' -ForegroundColor Green

# ─── Cleanup and reboot ───────────────────────────────────────────────────────

try { net use $DeployShare /delete *>$null } catch {}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Green
Write-Host "   Done: $($os.Label) -> $computerName" -ForegroundColor Green
Write-Host '   Rebooting in 15 seconds...               ' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''
Start-Sleep 15
wpeutil reboot
