# 05-install-drivers.ps1
# Post-install driver installation for imaged PCs.
#
# Detects the machine model via WMI, looks up the driver pack in the
# manifest on the deploy share, and installs any missing drivers with
# pnputil. This is a complement to the offline DISM injection done in
# WinPE — it catches anything that needs to run in a live Windows session
# (e.g. software components, app-install-style drivers) and handles
# re-imaging or in-place driver updates.
#
# USAGE: .\05-install-drivers.ps1
#        .\05-install-drivers.ps1 -DeployShare \\192.168.5.141\deploy$ -DryRun
#        .\05-install-drivers.ps1 -Force   # re-install even if no errors found

param(
    [string]$DeployShare = '\\192.168.5.141\deploy$',
    [switch]$DryRun,
    [switch]$Force   # install even if pnputil reports no problem devices
)

$ErrorActionPreference = 'Stop'

# ─── Detect model ─────────────────────────────────────────────────────────────
Write-Host '==> Detecting hardware model...' -ForegroundColor Cyan

$wmiCS   = Get-WmiObject -Class Win32_ComputerSystem
$wmiBios = Get-WmiObject -Class Win32_BIOS
$hwMfr   = $wmiCS.Manufacturer.Trim()
$hwModel = $wmiCS.Model.Trim()
$hwSerial = $wmiBios.SerialNumber.Trim()

Write-Host "  Manufacturer : $hwMfr"
Write-Host "  Model        : $hwModel"
Write-Host "  Serial       : $hwSerial"

# ─── Check for problem devices ────────────────────────────────────────────────
$problemDevices = Get-PnpDevice | Where-Object { $_.Status -in 'Error', 'Unknown', 'Degraded' }
if ($problemDevices.Count -gt 0) {
    Write-Host ''
    Write-Host "  $($problemDevices.Count) device(s) with driver issues:" -ForegroundColor Yellow
    $problemDevices | ForEach-Object { Write-Host "    [$($_.Status)] $($_.FriendlyName) ($($_.InstanceId))" -ForegroundColor Yellow }
} else {
    Write-Host '  No problem devices detected.' -ForegroundColor Green
    if (-not $Force) {
        Write-Host '  Skipping driver install (use -Force to install anyway).' -ForegroundColor DarkGray
        exit 0
    }
    Write-Host '  -Force specified — installing driver pack anyway.' -ForegroundColor DarkGray
}

# ─── Load manifest ────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Looking up driver pack...' -ForegroundColor Cyan

$manifestPath = "$DeployShare\drivers\manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "  ERROR: Driver manifest not found at $manifestPath" -ForegroundColor Red
    Write-Host '  Ensure the deploy$ share is accessible and drivers\manifest.json exists.'
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Match by wmiModels list, then fall back to normalized key
function Get-NormalizedModelKey([string]$Manufacturer, [string]$Model) {
    $mdl = $Model.Trim()
    $mfr = $Manufacturer.Trim()
    if ($mdl -imatch "^$([regex]::Escape($mfr))\s+") { $mdl = $mdl.Substring($mfr.Length).TrimStart() }
    $key = "$mfr-$mdl" -replace '[^A-Za-z0-9]', '-' -replace '-{2,}', '-' -replace '^-|-$', ''
    return $key.ToLower()
}

$matched  = $null
$normalKey = Get-NormalizedModelKey -Manufacturer $hwMfr -Model $hwModel

foreach ($prop in $manifest.models.PSObject.Properties) {
    if ($prop.Value.wmiModels -contains $hwModel) { $matched = $prop.Value; break }
}
if (-not $matched) {
    foreach ($prop in $manifest.models.PSObject.Properties) {
        if ($prop.Name -eq $normalKey) { $matched = $prop.Value; break }
    }
}

if (-not $matched) {
    Write-Host "  WARN: Model '$hwModel' (key: $normalKey) not in driver manifest." -ForegroundColor Yellow
    Write-Host '  To add it: edit drivers\manifest.json and run 09-update-driver-warehouse.ps1 on pc-deploy.' -ForegroundColor Yellow
    exit 0
}

Write-Host "  Manifest entry : $($matched.manufacturer) $($matched.model)"
Write-Host "  Driver path    : $($matched.driverPath)"

$driverPath = "$DeployShare\drivers\$($matched.driverPath)"
if (-not (Test-Path $driverPath)) {
    Write-Host "  ERROR: Driver folder not found: $driverPath" -ForegroundColor Red
    Write-Host '  Run 09-update-driver-warehouse.ps1 on pc-deploy to populate the driver warehouse.' -ForegroundColor Yellow
    exit 1
}

$infFiles = Get-ChildItem $driverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
Write-Host "  Found $($infFiles.Count) .inf file(s)." -ForegroundColor Green

# ─── Install drivers ──────────────────────────────────────────────────────────
Write-Host ''
Write-Host "==> Installing drivers for $hwModel from $driverPath ..." -ForegroundColor Cyan

if ($DryRun) {
    Write-Host '  DryRun: would run pnputil /add-driver *.inf /install /recurse' -ForegroundColor Yellow
    exit 0
}

$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
$p = Start-Process pnputil -ArgumentList "/add-driver `"$driverPath\*.inf`" /install /recurse /subdirs" `
     -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
$out = Get-Content $o -Raw; Get-Content $e -Raw | Where-Object { $_ } | Write-Host -ForegroundColor DarkGray
Remove-Item $o,$e -ErrorAction SilentlyContinue

if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 259) {   # 259 = no drivers added (all current)
    Write-Host '  Driver installation complete.' -ForegroundColor Green
} else {
    Write-Host "  WARN: pnputil exited $($p.ExitCode) — some drivers may not have installed." -ForegroundColor Yellow
}

# ─── Re-check problem devices ─────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Re-checking device status...' -ForegroundColor Cyan
$stillBroken = Get-PnpDevice | Where-Object { $_.Status -in 'Error', 'Unknown', 'Degraded' }
if ($stillBroken.Count -gt 0) {
    Write-Host "  $($stillBroken.Count) device(s) still need attention:" -ForegroundColor Yellow
    $stillBroken | ForEach-Object { Write-Host "    [$($_.Status)] $($_.FriendlyName)" -ForegroundColor Yellow }
} else {
    Write-Host '  All devices OK.' -ForegroundColor Green
}

Write-Host ''
Write-Host '==> Driver installation complete.' -ForegroundColor Green
