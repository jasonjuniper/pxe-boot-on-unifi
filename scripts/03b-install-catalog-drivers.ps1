# 03b-install-catalog-drivers.ps1
# Juniper Design - Post-imaging: install confirmed drivers from inventory catalog.
#
# Queries GET /api/drivers?manufacturer=X&model=Y&os_filter=Z&status=confirmed_working
# and installs each driver silently.  Run after imaging, on first logon or via
# FirstLogonCommands / post-install sequence (after 03-windows-update.ps1).
#
# Requires:
#   - Network reachable to 192.168.5.141:8080 (inventory server)
#   - Deploy share reachable at \\192.168.5.141\deploy$ (or adjust $DriverRoot below)
#   - 1Password CLI (op.exe) authenticated for any secrets; currently no secrets needed
#     for the /api/ endpoint (no auth required on that prefix).
#
# Usage:
#   .\03b-install-catalog-drivers.ps1
#   .\03b-install-catalog-drivers.ps1 -Manufacturer "Dell" -Model "XPS 13 9380"

param(
    [string]$Manufacturer = '',
    [string]$Model        = '',
    [string]$OsFilter     = '',          # e.g. "Windows 11" - auto-detected if empty
    [string]$DriverRoot   = '\\192.168.5.141\deploy$\drivers',
    [string]$InvApi       = 'http://192.168.5.141:8080',
    [switch]$IncludeUnconfirmed          # also install 'unconfirmed' drivers (first-run new hardware)
)

$ErrorActionPreference = 'Continue'

# --- Auto-detect hardware if not supplied -----------------------------------

if (-not $Manufacturer -or -not $Model) {
    $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        if (-not $Manufacturer) { $Manufacturer = $cs.Manufacturer.Trim() }
        if (-not $Model)        { $Model        = $cs.Model.Trim() }
    }
}

if (-not $OsFilter) {
    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    $OsFilter = if ($os.Caption -imatch 'Windows 11') { 'Windows 11' }
                elseif ($os.Caption -imatch 'Windows 10') { 'Windows 10' }
                else { 'Windows 11' }
}

Write-Host ''
Write-Host '  == Catalog Driver Install ==============================' -ForegroundColor Cyan
Write-Host "     Manufacturer : $Manufacturer"
Write-Host "     Model        : $Model"
Write-Host "     OS filter    : $OsFilter"
Write-Host "     API          : $InvApi"
Write-Host "     Driver root  : $DriverRoot"
Write-Host ''

# --- Query inventory catalog ------------------------------------------------

$statuses = @('confirmed_working')
if ($IncludeUnconfirmed) { $statuses += 'unconfirmed' }

$allDrivers = [System.Collections.Generic.List[object]]::new()

foreach ($status in $statuses) {
    $url = "$InvApi/api/drivers?" +
           "manufacturer=$([uri]::EscapeDataString($Manufacturer))" +
           "&model=$([uri]::EscapeDataString($Model))" +
           "&os_filter=$([uri]::EscapeDataString($OsFilter))" +
           "&status=$status"
    try {
        $batch = Invoke-RestMethod $url -TimeoutSec 10 -ErrorAction Stop
        if ($batch) { foreach ($d in $batch) { $allDrivers.Add($d) | Out-Null } }
    } catch {
        Write-Host "  WARN: Driver catalog query failed ($status): $_" -ForegroundColor Yellow
    }
}

if ($allDrivers.Count -eq 0) {
    Write-Host "  No catalog drivers found for $Model / $OsFilter." -ForegroundColor DarkGray
    Write-Host '  (Inbox + Windows Update drivers only.)'
    exit 0
}

Write-Host "  Found $($allDrivers.Count) driver(s) to install." -ForegroundColor Cyan
Write-Host ''

# --- Install each driver ----------------------------------------------------

$installed = 0
$skipped   = 0
$failed    = 0
$rebootNeeded = $false

foreach ($drv in $allDrivers) {
    $name = $drv.driver_name
    $ver  = $drv.driver_version
    $cat  = $drv.category
    $stat = $drv.status

    # Resolve path: prefer unc_path (fully qualified), fall back to file_path under DriverRoot
    $drvPath = if ($drv.unc_path)    { $drv.unc_path }
               elseif ($drv.file_path) { Join-Path $DriverRoot $drv.file_path }
               else                    { $null }

    $label = "[$cat] $name v$ver"
    if ($stat -eq 'unconfirmed') { $label += ' (unconfirmed)' }
    if ($drv.update_available)   { $label += " [update available: v$($drv.latest_version)]" }

    if (-not $drvPath) {
        Write-Host "  SKIP $label - no file_path in catalog entry." -ForegroundColor Yellow
        $skipped++; continue
    }

    if (-not (Test-Path $drvPath)) {
        Write-Host "  SKIP $label - file not on share: $drvPath" -ForegroundColor Yellow
        $skipped++; continue
    }

    # Verify SHA256 if recorded
    if ($drv.sha256) {
        $hash = (Get-FileHash $drvPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($hash -and $hash -ne $drv.sha256) {
            Write-Host "  SKIP $label - SHA256 mismatch (expected $($drv.sha256.Substring(0,16))...)." -ForegroundColor Red
            $failed++; continue
        }
    }

    Write-Host "  Installing $label ..." -ForegroundColor Cyan

    $ext = [System.IO.Path]::GetExtension($drvPath).ToLower()
    $exitCode = 0

    try {
        switch ($ext) {
            '.inf' {
                $p = Start-Process pnputil.exe `
                    -ArgumentList "/add-driver `"$drvPath`" /install" `
                    -Wait -PassThru -NoNewWindow
                $exitCode = $p.ExitCode
            }
            '.msi' {
                $p = Start-Process msiexec.exe `
                    -ArgumentList "/i `"$drvPath`" /qn /norestart" `
                    -Wait -PassThru -NoNewWindow
                $exitCode = $p.ExitCode
            }
            '.exe' {
                # Use notes field for custom silent flags if recorded, else try /s /norestart
                $silentArgs = if ($drv.notes -imatch 'silent:\s*(.+)') { $matches[1].Trim() }
                              else { '/s /norestart' }
                $p = Start-Process $drvPath `
                    -ArgumentList $silentArgs `
                    -Wait -PassThru -NoNewWindow
                $exitCode = $p.ExitCode
            }
            default {
                Write-Host "    SKIP - unsupported extension '$ext'." -ForegroundColor Yellow
                $skipped++; continue
            }
        }
    } catch {
        Write-Host "    ERROR: $_" -ForegroundColor Red
        $failed++; continue
    }

    # 0 = success, 3010 = success + reboot required
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        if ($exitCode -eq 3010) { $rebootNeeded = $true }
        Write-Host "    OK (exit $exitCode)" -ForegroundColor Green
        $installed++
    } else {
        Write-Host "    WARN: exit code $exitCode - check manually." -ForegroundColor Yellow
        $failed++
    }
}

# --- Summary ----------------------------------------------------------------

Write-Host ''
Write-Host "  -------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host "  Installed : $installed" -ForegroundColor $(if ($installed -gt 0) { 'Green' } else { 'DarkGray' })
if ($skipped -gt 0) { Write-Host "  Skipped   : $skipped" -ForegroundColor Yellow }
if ($failed  -gt 0) { Write-Host "  Failed    : $failed"  -ForegroundColor Red }
if ($rebootNeeded)  { Write-Host "  NOTE: One or more drivers require a reboot." -ForegroundColor Yellow }
Write-Host ''

exit $(if ($failed -gt 0) { 1 } else { 0 })
