# 09-update-driver-warehouse.ps1
# Driver warehouse sanity check and gap report.
#
# Queries the Juniper inventory system for:
#   1. All machine models seen in the environment (via /api/devices.json)
#   2. The tracked driver catalog with status + version info (via /api/drivers)
#
# Cross-references against the driver manifest.json on the deploy share
# and the actual driver folders on disk. Reports:
#   - Models in inventory but NOT in the manifest (need driver packs added)
#   - Models in the manifest but with NO driver files on disk (need download)
#   - Driver catalog entries with updates available (newer version known)
#   - Driver catalog entries marked confirmed_buggy (action needed)
#   - Models fully covered (manifest + files present)
#
# Run on pc-deploy (or any machine with deploy$ share access) whenever you
# image a new model or want to audit warehouse coverage.
#
# USAGE (on pc-deploy, as Administrator):
#   .\09-update-driver-warehouse.ps1
#   .\09-update-driver-warehouse.ps1 -InventoryUrl http://192.168.5.141:8080
#   .\09-update-driver-warehouse.ps1 -DeployRoot C:\deploy -SkipInventory

param(
    [string]$DeployRoot    = 'C:\deploy',
    [string]$InventoryUrl  = 'http://192.168.5.141:8080',
    [switch]$SkipInventory  # skip API query, just audit the local warehouse
)

$ErrorActionPreference = 'Continue'

$driversRoot  = "$DeployRoot\drivers"
$manifestPath = "$driversRoot\manifest.json"

Write-Host ''
Write-Host ('=' * 65) -ForegroundColor Cyan
Write-Host '  Juniper Design - Driver Warehouse Audit' -ForegroundColor Cyan
Write-Host "  $(Get-Date)" -ForegroundColor Cyan
Write-Host ('=' * 65)
Write-Host ''

# --- Load manifest -------------------------------------------------------
Write-Host '==> Loading driver manifest...' -ForegroundColor Cyan

if (-not (Test-Path $manifestPath)) {
    Write-Host "  ERROR: Manifest not found at $manifestPath" -ForegroundColor Red
    Write-Host '  Ensure the deploy share exists and drivers\manifest.json is present.'
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$manifestModels = $manifest.models.PSObject.Properties

Write-Host "  $($manifestModels.Count) model(s) in manifest." -ForegroundColor Green

# --- Query inventory API - machine models --------------------------------
$inventoryModels = @()

if (-not $SkipInventory) {
    Write-Host ''
    Write-Host "==> Querying inventory system at $InventoryUrl ..." -ForegroundColor Cyan

    try {
        $rawDevices = Invoke-RestMethod -Uri "$InventoryUrl/api/devices.json" `
                        -Method Get -TimeoutSec 15 -ErrorAction Stop
        Write-Host "  $($rawDevices.Count) device record(s) from /api/devices.json" -ForegroundColor Green

        $grouped = $rawDevices | Where-Object { $_.model } |
            Group-Object -Property model

        $inventoryModels = $grouped | ForEach-Object {
            [pscustomobject]@{
                Model        = $_.Name
                Manufacturer = ($_.Group[0].vendor ?? '')
                Count        = $_.Count
                Serials      = ($_.Group | Select-Object -ExpandProperty serial_number -ErrorAction SilentlyContinue) -join ', '
            }
        } | Sort-Object -Property Count -Descending

        Write-Host "  Unique models in inventory: $($inventoryModels.Count)"
    } catch {
        Write-Host "  Could not reach $InventoryUrl/api/devices.json: $_" -ForegroundColor Yellow
        Write-Host '  Continuing with manifest-only audit.' -ForegroundColor DarkGray
    }

    # --- Query driver catalog from inventory --------------------------------
    Write-Host ''
    Write-Host '==> Querying driver catalog from inventory...' -ForegroundColor Cyan
    $catalogDrivers = @()
    try {
        $catalogDrivers = Invoke-RestMethod -Uri "$InventoryUrl/api/drivers" `
                            -Method Get -TimeoutSec 15 -ErrorAction Stop
        Write-Host "  $($catalogDrivers.Count) driver entries in catalog." -ForegroundColor Green
    } catch {
        Write-Host "  Could not reach $InventoryUrl/api/drivers: $_" -ForegroundColor Yellow
    }

    # Report catalog issues
    $updates = $catalogDrivers | Where-Object { $_.update_available -eq $true }
    $buggy   = $catalogDrivers | Where-Object { $_.status -eq 'confirmed_buggy' }

    if ($updates.Count -gt 0) {
        Write-Host ''
        Write-Host "  [!!] $($updates.Count) driver(s) with a newer version available:" -ForegroundColor Yellow
        foreach ($d in $updates) {
            $model = if ($d.model) { "$($d.manufacturer) $($d.model)" } else { "$($d.manufacturer) (all models)" }
            Write-Host "       $model - $($d.driver_name)" -ForegroundColor Yellow
            Write-Host "       On disk: $($d.driver_version)  Latest: $($d.latest_version)" -ForegroundColor DarkGray
            if ($d.vendor_url) {
                Write-Host "       Vendor : $($d.vendor_url)" -ForegroundColor DarkGray
            }
            Write-Host "       Path   : $($d.unc_path)" -ForegroundColor DarkGray
            Write-Host ''
        }
    }

    if ($buggy.Count -gt 0) {
        Write-Host ''
        Write-Host "  [!!] $($buggy.Count) driver(s) marked confirmed_buggy:" -ForegroundColor Red
        foreach ($d in $buggy) {
            $model = if ($d.model) { "$($d.manufacturer) $($d.model)" } else { "$($d.manufacturer) (all models)" }
            Write-Host "       $model - $($d.driver_name)" -ForegroundColor Red
            if ($d.status_notes) {
                Write-Host "       Note: $($d.status_notes)" -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }
}

# --- Audit warehouse coverage --------------------------------------------
Write-Host ''
Write-Host '==> Auditing driver warehouse on disk...' -ForegroundColor Cyan

$covered   = @()
$noFiles   = @()
$notInMfst = @()

foreach ($prop in $manifestModels) {
    $entry      = $prop.Value
    $driverPath = Join-Path $driversRoot ($entry.driverPath -replace '/', '\')
    $infCount   = 0
    if (Test-Path $driverPath) {
        $infCount = (Get-ChildItem $driverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    }
    $entry | Add-Member -NotePropertyName '_key'      -NotePropertyValue $prop.Name -Force
    $entry | Add-Member -NotePropertyName '_infCount' -NotePropertyValue $infCount  -Force
    $entry | Add-Member -NotePropertyName '_path'     -NotePropertyValue $driverPath -Force

    if ($infCount -gt 0) { $covered += $entry } else { $noFiles += $entry }
}

foreach ($inv in $inventoryModels) {
    $found = $false
    foreach ($prop in $manifestModels) {
        if ($prop.Value.wmiModels -contains $inv.Model) { $found = $true; break }
    }
    if (-not $found) { $notInMfst += $inv }
}

# --- Report --------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 65)
Write-Host '  RESULTS' -ForegroundColor Cyan
Write-Host ('-' * 65)

Write-Host ''
Write-Host "  [OK] $($covered.Count) model(s) fully covered (manifest + driver files):" -ForegroundColor Green
foreach ($e in $covered) {
    $mfr = if ($e.PSObject.Properties['manufacturer']) { $e.manufacturer } else { '' }
    $mdl = if ($e.PSObject.Properties['model'])        { $e.model }        else { $e._key }
    Write-Host "       $mfr $mdl  ($($e._infCount) .inf files)" -ForegroundColor Green
}

if ($noFiles.Count -gt 0) {
    Write-Host ''
    Write-Host "  [!!] $($noFiles.Count) model(s) in manifest but NO driver files on disk:" -ForegroundColor Yellow
    foreach ($e in $noFiles) {
        $mfr = if ($e.PSObject.Properties['manufacturer']) { $e.manufacturer } else { '' }
        $mdl = if ($e.PSObject.Properties['model'])        { $e.model }        else { $e._key }
        Write-Host "       $mfr $mdl" -ForegroundColor Yellow
        Write-Host "       Path   : $($e._path)" -ForegroundColor DarkGray
        if ($e.PSObject.Properties['vendorUrl'] -and $e.vendorUrl) {
            Write-Host "       URL    : $($e.vendorUrl)" -ForegroundColor DarkGray
        }
        Write-Host ''
    }
}

if ($notInMfst.Count -gt 0) {
    Write-Host ''
    Write-Host "  [!!] $($notInMfst.Count) model(s) seen in inventory but NOT in manifest:" -ForegroundColor Red
    foreach ($inv in $notInMfst) {
        Write-Host "       $($inv.Manufacturer) $($inv.Model)  ($($inv.Count) machine(s))" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  To add missing models:' -ForegroundColor Yellow
    Write-Host '    1. Add driver entries in the inventory web UI at http://192.168.5.141:8080/drivers'
    Write-Host '       - Set file_path relative to C:\deploy\drivers\ (e.g. dell-xps-13-9380\network\Intel-NIC.exe)'
    Write-Host '       - Mark status = confirmed_working once tested'
    Write-Host '    2. Edit drivers\manifest.json for the coarse-grained folder entry used by DISM offline injection'
    Write-Host '       OR fetch the auto-generated manifest from: GET /api/drivers/manifest.json'
    Write-Host '    3. Download driver pack from vendor and extract to C:\deploy\drivers\<path>\'
    Write-Host ''
    Write-Host '  Dell:   support.dell.com -> Driver Pack CAB'
    Write-Host '    expand -F:* DriverPack.cab C:\deploy\drivers\dell-<model>\'
    Write-Host ''
    Write-Host '  HP:     support.hp.com -> HP Driver Pack .exe'
    Write-Host '    HPDriverPack.exe /e /s /f C:\deploy\drivers\hp-<model>\'
    Write-Host ''
    Write-Host '  Lenovo: support.lenovo.com -> SCCM/WinPE Driver Pack ZIP'
    Write-Host '    Extract to C:\deploy\drivers\lenovo-<model>\'
}

# --- Summary -------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 65)
Write-Host "  SUMMARY: $($covered.Count) covered  |  $($noFiles.Count) missing files  |  $($notInMfst.Count) not in manifest"
if ($noFiles.Count -eq 0 -and $notInMfst.Count -eq 0) {
    Write-Host '  Warehouse is fully stocked for all known inventory models.' -ForegroundColor Green
} else {
    Write-Host '  Action required -- see items marked [!!] above.' -ForegroundColor Yellow
}
Write-Host ('-' * 65)
Write-Host ''
