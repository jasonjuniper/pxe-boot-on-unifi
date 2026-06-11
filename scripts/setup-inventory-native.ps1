# setup-inventory-native.ps1
# Deploys the Computer Inventory server natively on pc-deploy — no Docker.
# Run AS ADMINISTRATOR on pc-deploy (192.168.5.141).
#
# PREREQUISITES:
#   1. 1Password CLI (op.exe) installed and authenticated: op signin
#   2. Internet access for winget downloads
#   3. Run AS ADMINISTRATOR
#   4. Inventory repo accessible (copy the 'app' folder alongside this script,
#      or set -AppSrc to the app directory path)
#
# WHAT IT INSTALLS:
#   PostgreSQL 16      → Windows service 'postgresql-x64-16'
#   Python 3.12        → C:\Program Files\Python312\
#   nmap               → C:\Program Files (x86)\Nmap\
#   NSSM               → C:\nssm\  (wraps uvicorn as a Windows service)
#   Inventory app      → C:\inventory\
#
# SECRETS — all pulled from 1Password at install time. The DATABASE_URL is
# stored in the NSSM service's registry Environment block
# (HKLM\SYSTEM\CurrentControlSet\Services\JuniperInventory) which requires
# Admin rights to read — never written to a plaintext file on disk.
#
# 1Password items to create before running:
#   op://Private/inventory-server/db-password       (password for 'inv' PG user)
#   op://Private/inventory-server/pg-superpassword  (postgres superuser, setup only)
#   op://Private/inventory-server/unifi-host        (e.g. https://192.168.0.1)
#   op://Private/inventory-server/unifi-username
#   op://Private/inventory-server/unifi-password
#
# USAGE:
#   .\setup-inventory-native.ps1
#   .\setup-inventory-native.ps1 -RestoreFrom 'C:\inventory_backup.sql'
#   .\setup-inventory-native.ps1 -SkipPostgres -SkipPython   # re-deploy app only

param(
    [string]$InstallRoot    = 'C:\inventory',
    [string]$AppSrc         = '',           # path to 'app' dir; auto-detected if blank
    [string]$Port           = '8080',
    [string]$PgPort         = '5432',
    [string]$PgUser         = 'inv',
    [string]$PgDb           = 'inventory',
    [string]$ServiceName    = 'JuniperInventory',
    [string]$OpDbPw         = 'op://Private/inventory-server/db-password',
    [string]$OpPgSuperPw    = 'op://Private/inventory-server/pg-superpassword',
    [string]$OpUnifiHost    = 'op://Private/inventory-server/unifi-host',
    [string]$OpUnifiUser    = 'op://Private/inventory-server/unifi-username',
    [string]$OpUnifiPw      = 'op://Private/inventory-server/unifi-password',
    [string]$RestoreFrom    = '',   # path to .sql backup file to restore
    [switch]$SkipPostgres,
    [switch]$SkipPython
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# ─── Privilege check ─────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: Run this script AS ADMINISTRATOR.' -ForegroundColor Red; exit 1
}

# ─── op CLI check ─────────────────────────────────────────────────────────────
$opExe = (Get-Command op -ErrorAction SilentlyContinue)?.Source
if (-not $opExe) { $opExe = 'C:\Program Files\1Password CLI\op.exe' }
if (-not (Test-Path $opExe)) {
    Write-Host 'ERROR: op CLI not found. Install from https://developer.1password.com/docs/cli' -ForegroundColor Red; exit 1
}
try { & $opExe account list --format=json 2>$null | ConvertFrom-Json | Out-Null }
catch { Write-Host 'ERROR: op not authenticated. Run: op signin' -ForegroundColor Red; exit 1 }

# ─── Locate app source ────────────────────────────────────────────────────────
if (-not $AppSrc) {
    # Try common relative paths from this script
    $candidates = @(
        (Join-Path $PSScriptRoot '..\app'),
        'C:\dev\inventory\Computer Inventory\app',
        "$env:USERPROFILE\source\inventory\app"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'main.py')) { $AppSrc = $c; break }
    }
}
if (-not $AppSrc -or -not (Test-Path (Join-Path $AppSrc 'main.py'))) {
    Write-Host 'ERROR: Cannot find inventory app source. Copy the app/ directory here and re-run,' -ForegroundColor Red
    Write-Host '  or pass -AppSrc to the inventory app directory.' -ForegroundColor Red
    exit 1
}
$AppSrc = (Resolve-Path $AppSrc).Path
Write-Host "App source: $AppSrc" -ForegroundColor DarkGray

# ─── Read secrets from 1Password ─────────────────────────────────────────────
Write-Host ''
Write-Host '==> Reading secrets from 1Password...' -ForegroundColor Cyan

function Read-OpSecret([string]$ref) {
    $val = (& $opExe read $ref 2>$null)
    if (-not $val) { throw "Could not read: $ref`nCheck that the 1Password item exists and op is authenticated." }
    return $val
}

$dbPw      = Read-OpSecret $OpDbPw
$pgSuperPw = Read-OpSecret $OpPgSuperPw
$unifiHost = (& $opExe read $OpUnifiHost 2>$null) -as [string]
$unifiUser = (& $opExe read $OpUnifiUser 2>$null) -as [string]
$unifiPw   = (& $opExe read $OpUnifiPw  2>$null) -as [string]
Write-Host '  Secrets loaded.' -ForegroundColor Green

# ─── PostgreSQL 16 ───────────────────────────────────────────────────────────
$pgBin = 'C:\Program Files\PostgreSQL\16\bin'
$psql  = Join-Path $pgBin 'psql.exe'

if (-not $SkipPostgres) {
    Write-Host ''; Write-Host '==> Installing PostgreSQL 16...' -ForegroundColor Cyan
    $pgSvc = Get-Service 'postgresql-x64-16' -ErrorAction SilentlyContinue
    if ($pgSvc) {
        Write-Host '  Already installed.' -ForegroundColor DarkGray
    } else {
        winget install --id PostgreSQL.PostgreSQL.16 --silent `
            --accept-package-agreements --accept-source-agreements `
            --override "--mode unattended --superpassword `"$pgSuperPw`" --servicename postgresql-x64-16 --datadir `"C:\PostgreSQL\16\data`""
        Start-Sleep 5
    }
    $pgSvc = Get-Service 'postgresql-x64-16' -ErrorAction SilentlyContinue
    if (-not $pgSvc) { Write-Host 'ERROR: PostgreSQL service not found after install.' -ForegroundColor Red; exit 1 }
    if ($pgSvc.Status -ne 'Running') { Start-Service 'postgresql-x64-16'; Start-Sleep 3 }
    Write-Host '  PostgreSQL 16 running.' -ForegroundColor Green
} else {
    Write-Host '==> Skipping PostgreSQL install (-SkipPostgres).' -ForegroundColor DarkGray
}

# ─── Create DB user + database ────────────────────────────────────────────────
Write-Host ''; Write-Host "==> Configuring database '$PgDb'..." -ForegroundColor Cyan

if (Test-Path $psql) {
    $env:PGPASSWORD = $pgSuperPw

    # Create role if not exists
    $sql = "DO `$`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$PgUser') THEN CREATE ROLE $PgUser LOGIN PASSWORD '$dbPw'; ELSE ALTER ROLE $PgUser WITH PASSWORD '$dbPw'; END IF; END `$`$;"
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    Start-Process $psql "-U postgres -p $PgPort -c `"$sql`"" -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    Get-Content $e | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Remove-Item $o,$e -ErrorAction SilentlyContinue

    # Create database if not exists
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    Start-Process $psql "-U postgres -p $PgPort -tAc `"SELECT 1 FROM pg_database WHERE datname='$PgDb'`"" -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    $exists = (Get-Content $o -ErrorAction SilentlyContinue).Trim()
    Remove-Item $o,$e -ErrorAction SilentlyContinue

    if ($exists -ne '1') {
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        Start-Process $psql "-U postgres -p $PgPort -c `"CREATE DATABASE $PgDb OWNER $PgUser ENCODING 'UTF8'`"" -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        Write-Host "  Created database '$PgDb' (empty — run with -RestoreFrom to populate)." -ForegroundColor Green
    } else {
        Write-Host "  Database '$PgDb' already exists." -ForegroundColor DarkGray
    }
    $env:PGPASSWORD = ''
} else {
    Write-Host "  WARN: psql not found at $psql — skipping DB setup." -ForegroundColor Yellow
}

# ─── Python 3.12 ─────────────────────────────────────────────────────────────
$pyExe = 'C:\Program Files\Python312\python.exe'
if (-not $SkipPython) {
    Write-Host ''; Write-Host '==> Installing Python 3.12...' -ForegroundColor Cyan
    if (-not (Test-Path $pyExe)) {
        winget install --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
        Start-Sleep 3
    }
    if (-not (Test-Path $pyExe)) { $pyExe = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" }
    if (-not (Test-Path $pyExe)) { Write-Host 'ERROR: Python 3.12 not found after install.' -ForegroundColor Red; exit 1 }
    Write-Host "  Python: $pyExe" -ForegroundColor Green
} else {
    Write-Host '==> Skipping Python install (-SkipPython).' -ForegroundColor DarkGray
    if (-not (Test-Path $pyExe)) { $pyExe = (Get-Command python -ErrorAction SilentlyContinue)?.Source }
}

# ─── nmap ─────────────────────────────────────────────────────────────────────
Write-Host ''; Write-Host '==> Checking nmap...' -ForegroundColor Cyan
if (Test-Path 'C:\Program Files (x86)\Nmap\nmap.exe') {
    Write-Host '  Already installed.' -ForegroundColor DarkGray
} else {
    winget install --id Insecure.Nmap --silent --accept-package-agreements --accept-source-agreements
    Write-Host '  nmap installed.' -ForegroundColor Green
}

# ─── NSSM ─────────────────────────────────────────────────────────────────────
$nssmExe = 'C:\nssm\nssm.exe'
Write-Host ''; Write-Host '==> Checking NSSM...' -ForegroundColor Cyan
if (-not (Test-Path $nssmExe)) {
    Write-Host '  Downloading NSSM 2.24...' -ForegroundColor DarkGray
    $nssmZip = "$env:TEMP\nssm-2.24.zip"
    Invoke-WebRequest 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $nssmZip
    New-Item 'C:\nssm' -ItemType Directory -Force | Out-Null
    Expand-Archive $nssmZip -DestinationPath "$env:TEMP\nssm_extract" -Force
    Copy-Item "$env:TEMP\nssm_extract\nssm-2.24\win64\nssm.exe" $nssmExe -Force
    Remove-Item $nssmZip,"$env:TEMP\nssm_extract" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  NSSM installed at $nssmExe" -ForegroundColor Green
} else {
    Write-Host '  Already present.' -ForegroundColor DarkGray
}

# ─── Deploy app files ─────────────────────────────────────────────────────────
Write-Host ''; Write-Host "==> Deploying app to $InstallRoot ..." -ForegroundColor Cyan
$appDst = Join-Path $InstallRoot 'app'
foreach ($d in @($InstallRoot, $appDst, "$InstallRoot\exports", "$InstallRoot\scanners", "$InstallRoot\logs")) {
    New-Item $d -ItemType Directory -Force | Out-Null
}
Copy-Item "$AppSrc\*" $appDst -Recurse -Force

# Copy scanners if present in repo
$scannersSrc = Join-Path (Split-Path $AppSrc -Parent) 'scanners'
if (Test-Path $scannersSrc) {
    Copy-Item "$scannersSrc\*" "$InstallRoot\scanners" -Recurse -Force
}

# Patch main.py: fix hardcoded /app/exports Docker path
$mainPy = Join-Path $appDst 'main.py'
$mainTxt = Get-Content $mainPy -Raw
if ($mainTxt -match 'Path\("/app/exports"\)') {
    $mainTxt = $mainTxt -replace [regex]::Escape('Path("/app/exports")'), 'Path(os.environ.get("EXPORT_DIR", str(Path(__file__).parent.parent / "exports")))'
    $mainTxt | Set-Content $mainPy -Encoding UTF8 -NoNewline
    Write-Host '  Patched main.py: /app/exports → EXPORT_DIR env var.' -ForegroundColor Green
}
Write-Host '  App files deployed.' -ForegroundColor Green

# ─── Virtual environment + pip ────────────────────────────────────────────────
Write-Host ''; Write-Host '==> Installing Python packages...' -ForegroundColor Cyan
$venvDir = Join-Path $InstallRoot 'venv'
if (-not (Test-Path "$venvDir\Scripts\python.exe")) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    Start-Process $pyExe "-m venv `"$venvDir`"" -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    Remove-Item $o,$e -ErrorAction SilentlyContinue
}
$venvPip = "$venvDir\Scripts\pip.exe"
$reqFile = Join-Path $appDst 'requirements.txt'
$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
$p = Start-Process $venvPip "install -r `"$reqFile`" --quiet" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
if ($p.ExitCode -ne 0) {
    Write-Host '  pip errors:' -ForegroundColor Yellow
    Get-Content $e | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
} else { Write-Host '  Packages installed.' -ForegroundColor Green }
Remove-Item $o,$e -ErrorAction SilentlyContinue

# ─── Restore backup (optional) ────────────────────────────────────────────────
if ($RestoreFrom -and (Test-Path $RestoreFrom)) {
    Write-Host ''; Write-Host "==> Restoring database from $(Split-Path $RestoreFrom -Leaf)..." -ForegroundColor Cyan
    $env:PGPASSWORD = $pgSuperPw
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process $psql "-U postgres -p $PgPort -d $PgDb -f `"$RestoreFrom`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    $env:PGPASSWORD = ''
    if ($p.ExitCode -ne 0) {
        Write-Host "  WARN: psql exited $($p.ExitCode):" -ForegroundColor Yellow
        Get-Content $e | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else { Write-Host '  Backup restored.' -ForegroundColor Green }
    Remove-Item $o,$e -ErrorAction SilentlyContinue
}

# ─── Windows service via NSSM ─────────────────────────────────────────────────
Write-Host ''; Write-Host "==> Configuring Windows service '$ServiceName'..." -ForegroundColor Cyan

$uvicornExe = "$venvDir\Scripts\uvicorn.exe"
$dbUrl = "postgresql+psycopg://${PgUser}:${dbPw}@localhost:${PgPort}/${PgDb}"

# Remove existing service cleanly
$existingSvc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
    if ($existingSvc.Status -eq 'Running') { & $nssmExe stop $ServiceName confirm 2>$null }
    & $nssmExe remove $ServiceName confirm 2>$null
    Start-Sleep 2
}

# Install service
& $nssmExe install $ServiceName $uvicornExe `
    "main:app --host 0.0.0.0 --port $Port --app-dir `"$appDst`""
& $nssmExe set $ServiceName AppDirectory    $appDst
& $nssmExe set $ServiceName DisplayName     'Juniper Inventory Server'
& $nssmExe set $ServiceName Description     'Computer Inventory web service (FastAPI/uvicorn) — Juniper Design'
& $nssmExe set $ServiceName Start           SERVICE_AUTO_START
& $nssmExe set $ServiceName ObjectName      LocalSystem
& $nssmExe set $ServiceName AppStdout       "$InstallRoot\logs\inventory.log"
& $nssmExe set $ServiceName AppStderr       "$InstallRoot\logs\inventory-err.log"
& $nssmExe set $ServiceName AppRotateFiles  1
& $nssmExe set $ServiceName AppRotateOnline 1
& $nssmExe set $ServiceName AppRotateBytes  10485760  # 10 MB

# Environment vars in service registry (SYSTEM/Admin read-only)
& $nssmExe set $ServiceName AppEnvironmentExtra `
    "DATABASE_URL=$dbUrl" `
    "EXPORT_DIR=$InstallRoot\exports" `
    "UNIFI_HOST=$unifiHost" `
    "UNIFI_USERNAME=$unifiUser" `
    "UNIFI_PASSWORD=$unifiPw" `
    "UNIFI_SITE=default"

# Clear secrets from memory
$dbPw = ''; $pgSuperPw = ''; $unifiPw = ''; $dbUrl = ''

Write-Host "  Service '$ServiceName' configured." -ForegroundColor Green

# ─── Firewall ─────────────────────────────────────────────────────────────────
$fwName = "Juniper Inventory Port $Port"
if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    Write-Host "  Firewall: opened port $Port." -ForegroundColor Green
}

# ─── Start + health check ─────────────────────────────────────────────────────
Write-Host ''; Write-Host "==> Starting '$ServiceName'..." -ForegroundColor Cyan
& $nssmExe start $ServiceName
Start-Sleep 6

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if ($svc?.Status -eq 'Running') {
    try {
        $hc = Invoke-RestMethod "http://localhost:$Port/healthz" -TimeoutSec 10
        if ($hc.ok) { Write-Host "  Service UP — http://localhost:$Port/" -ForegroundColor Green }
    } catch {
        Write-Host "  Service running but /healthz not yet ready — check logs." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARN: Service not running. Check: Get-Content $InstallRoot\logs\inventory-err.log" -ForegroundColor Yellow
}

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Green
Write-Host '  Juniper Inventory — Native Install Complete' -ForegroundColor Green
Write-Host ('=' * 60)
Write-Host ''
Write-Host "  Web UI  : http://$(hostname):$Port/"
Write-Host "  Service : $ServiceName  (auto-starts on boot)"
Write-Host "  Logs    : $InstallRoot\logs\"
Write-Host "  App     : $appDst"
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host "  1. Verify: Invoke-RestMethod http://192.168.5.141:$Port/healthz"
Write-Host '  2. Copy backup to pc-deploy and restore:'
Write-Host "       .\setup-inventory-native.ps1 -SkipPostgres -SkipPython -RestoreFrom 'C:\inventory_backup.sql'"
Write-Host '  3. Once verified, stop Docker on ENG-2:'
Write-Host '       wsl -d Ubuntu -- docker stop inventory'
Write-Host '  4. Update 09-update-driver-warehouse.ps1 default -InventoryUrl (already updated in repo)'
Write-Host ''
