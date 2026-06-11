# 09-update-driver-warehouse.ps1
# Driver warehouse sanity check and gap report.
#
# Queries the Juniper inventory system for all machine models seen in the
# environment, compares against the driver manifest and the actual driver
# folders on the deploy share, and reports:
#   - Models in inventory but NOT in the manifest (need to be added)
#   - Models in the manifest but with NO driver files on disk (need download)
#   - Models fully covered (manifest + files present)
#
# Run this on pc-deploy (or any machine with access to the deploy share)
# whenever you image a new model or want to audit warehouse coverage.
#
# USAGE (on pc-deploy, as Administrator):
#   .\09-update-driver-warehouse.ps1
#   .\09-update-driver-warehouse.ps1 -InventoryUrl http://192.168.13.94:8080
#   .\09-update-driver-warehouse.ps1 -DeployRoot C:\deploy -SkipInventory

param(
    [string]$DeployRoot    = 'C:\deploy',
    [string]$InventoryUrl  = 'http://192.168.13.94:8080',
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

# ─── Load manifest ────────────────────────────────────────────────────────────
Write-Host '==> Loading driver manifest...' -ForegroundColor Cyan

if (-not (Test-Path $manifestPath)) {
    Write-Host "  ERROR: Manifest not found at $manifestPath" -ForegroundColor Red
    Write-Host '  Ensure the deploy share exists and drivers\manifest.json is present.'
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$manifestModels = $manifest.models.PSObject.Properties

Write-Host "  $($manifestModels.Count) model(s) in manifest." -ForegroundColor Green

# ─── Query inventory API ──────────────────────────────────────────────────────
$inventoryModels = @()   # array of [pscustomobject]@{ Model; Manufacturer; Count; Serials }

if (-not $SkipInventory) {
    Write-Host ''
    Write-Host "==> Querying inventory system at $InventoryUrl ..." -ForegroundColor Cyan

    # Probe common endpoint patterns — the API shape may vary
    $endpoints = @(
        '/api/machines',
        '/machines',
        '/api/assets',
        '/api/inventory',
        '/api/computers'
    )

    $rawMachines = $null
    $usedEndpoint = $null

    foreach ($ep in $endpoints) {
        try {
            $resp = Invoke-RestMethod -Uri "$InventoryUrl$ep" -Method Get -TimeoutSec 10 -ErrorAction Stop
            # Accept if response is a list or has a machines/items/data property
            if ($resp -is [array]) {
                $rawMachines = $resp
            } elseif ($resp.machines)   { $rawMachines = $resp.machines }
            elseif ($resp.items)        { $rawMachines = $resp.items    }
            elseif ($resp.data)         { $rawMachines = $resp.data     }
            elseif ($resp.computers)    { $rawMachines = $resp.computers }
            elseif ($resp.assets)       { $rawMachines = $resp.assets   }

            if ($rawMachines) { $usedEndpoint = $ep; break }
        } catch {
            # Try next endpoint silently
        }
    }

    if (-not $rawMachines) {
        # Try /docs or /openapi.json to help diagnose the API shape
        Write-Host '  Could not find machines via common endpoints.' -ForegroundColor Yellow
        Write-Host "  Tried: $($endpoints -join ', ')"
        try {
            $openapi = Invoke-RestMethod -Uri "$InventoryUrl/openapi.json" -Method Get -TimeoutSec 5 -ErrorAction Stop
            $routes = $openapi.paths.PSObject.Properties.Name | Where-Object { $_ -match 'machine|asset|computer|inventory' }
            Write-Host "  OpenAPI routes that may be relevant: $($routes -join ', ')" -ForegroundColor Yellow
            Write-Host "  Update the `$endpoints list in this script with the correct path." -ForegroundColor Yellow
        } catch {
            Write-Host "  No OpenAPI spec found. Check $InventoryUrl/docs in a browser." -ForegroundColor Yellow
        }
        Write-Host '  Continuing with manifest-only audit (-SkipInventory behavior).' -ForegroundColor DarkGray
    } else {
        Write-Host "  Endpoint: $usedEndpoint  ($($rawMachines.Count) machine record(s))" -ForegroundColor Green

        # Normalize field names — the agent may use different property names
        # Common patterns: model/Model, manufacturer/Manufacturer, hw_model, device_model
        $grouped = $rawMachines | ForEach-Object {
            $m = $_
            $model = $m.model ?? $m.Model ?? $m.hw_model ?? $m.device_model ?? $m.hardware_model ?? 'Unknown'
            $mfr   = $m.manufacturer ?? $m.Manufacturer ?? $m.vendor ?? $m.make ?? ''
            $sn    = $m.serial ?? $m.serial_number ?? $m.SerialNumber ?? $m.sn ?? ''
            [pscustomobject]@{ Model = $model.Trim(); Manufacturer = $mfr.Trim(); Serial = $sn.Trim() }
        } | Group-Object -Property Model

        $inventoryModels = $grouped | ForEach-Object {
            [pscustomobject]@{
                Model        = $_.Name
                Manufacturer = ($_.Group[0].Manufacturer)
                Count        = $_.Count
                Serials      = ($_.Group | Select-Object -ExpandProperty Serial) -join ', '
            }
        } | Sort-Object -Property Count -Descending

        Write-Host "  Unique models in inventory: $($inventoryModels.Count)"
    }
}

# ─── Audit warehouse coverage ─────────────────────────────────────────────────
Write-Host ''
Write-Host '==> Auditing driver warehouse...' -ForegroundColor Cyan

$covered    = @()   # in manifest + driver files exist
$noFiles    = @()   # in manifest but no .inf files found
$notInMfst  = @()   # in inventory but not in manifest

# Check each manifest entry for actual driver files
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

# Check inventory models against manifest
foreach ($inv in $inventoryModels) {
    $found = $false
    foreach ($prop in $manifestModels) {
        if ($prop.Value.wmiModels -contains $inv.Model) { $found = $true; break }
    }
    if (-not $found) { $notInMfst += $inv }
}

# ─── Report ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('─' * 65)
Write-Host '  RESULTS' -ForegroundColor Cyan
Write-Host ('─' * 65)

Write-Host ''
Write-Host "  [OK] $($covered.Count) model(s) fully covered (manifest + driver files):" -ForegroundColor Green
foreach ($e in $covered) {
    Write-Host "       $($e.manufacturer) $($e.model)  ($($e._infCount) .inf files)" -ForegroundColor Green
}

if ($noFiles.Count -gt 0) {
    Write-Host ''
    Write-Host "  [!!] $($noFiles.Count) model(s) in manifest but NO driver files on disk:" -ForegroundColor Yellow
    foreach ($e in $noFiles) {
        Write-Host "       $($e.manufacturer) $($e.model)" -ForegroundColor Yellow
        Write-Host "       Path   : $($e._path)" -ForegroundColor DarkGray
        Write-Host "       URL    : $($e.vendorUrl)" -ForegroundColor DarkGray
        if ($e.driverPackNotes) {
            Write-Host "       Notes  : $($e.driverPackNotes)" -ForegroundColor DarkGray
        }
        Write-Host ''
    }
}

if ($notInMfst.Count -gt 0) {
    Write-Host ''
    Write-Host "  [!!] $($notInMfst.Count) model(s) seen in inventory but NOT in manifest:" -ForegroundColor Red
    foreach ($inv in $notInMfst) {
        Write-Host "       $($inv.Manufacturer) $($inv.Model)  ($($inv.Count) machine(s), serial(s): $($inv.Serials))" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  To add missing models to the manifest:' -ForegroundColor Yellow
    Write-Host '    1. Edit drivers\manifest.json — add an entry for each model above.'
    Write-Host '    2. Download driver pack from vendor site (see manifest vendorUrl field).'
    Write-Host '    3. Extract driver pack to C:\deploy\drivers\<Manufacturer>\<Model>\'
    Write-Host '    4. Re-run this script to verify coverage.'
    Write-Host ''
    Write-Host '  Dell: Download "Driver Pack" CAB from support.dell.com'
    Write-Host '    expand -F:* DriverPack.cab C:\deploy\drivers\Dell\<Model>\'
    Write-Host ''
    Write-Host '  HP: Download "HP Driver Pack" .exe from support.hp.com'
    Write-Host '    HPDriverPack.exe /e /s /f C:\deploy\drivers\HP\<Model>\'
    Write-Host ''
    Write-Host '  Lenovo: Download "SCCM/WinPE Driver Pack" ZIP from support.lenovo.com'
    Write-Host '    Extract ZIP contents to C:\deploy\drivers\Lenovo\<Model>\'
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('─' * 65)
Write-Host "  SUMMARY: $($covered.Count) covered  |  $($noFiles.Count) missing files  |  $($notInMfst.Count) not in manifest"
if ($noFiles.Count -eq 0 -and $notInMfst.Count -eq 0) {
    Write-Host '  Warehouse is fully stocked for all known inventory models.' -ForegroundColor Green
} else {
    Write-Host '  Action required — see items marked [!!] above.' -ForegroundColor Yellow
}
Write-Host ('─' * 65)
Write-Host ''
