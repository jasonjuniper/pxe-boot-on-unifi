# setup-inventory-ps51.ps1 — PS5.1 compatible, no op CLI required
# Secrets passed as parameters by the remote launcher.
# Writes progress to stdout (redirected to setup.log by caller).

param(
    [string]$DbPw,
    [string]$PgSuperPw,
    [string]$UnifiHost,
    [string]$UnifiUser,
    [string]$UnifiPw,
    [string]$RestoreFrom = 'C:\inventory-src\inventory_backup.sql'
)

$ErrorActionPreference = 'Continue'

$InstallRoot = 'C:\inventory'
$AppSrc      = 'C:\inventory-src\app'
$PgUser      = 'inv'
$PgDb        = 'inventory'
$PgPort      = '5432'
$Port        = '8080'
$ServiceName = 'JuniperInventory'
$pgBin       = 'C:\Program Files\PostgreSQL\16\bin'
$pgData      = 'C:\Program Files\PostgreSQL\16\data'
$NssmExe     = 'C:\nssm\nssm.exe'
$PyExe       = 'C:\Python312\python.exe'

function Log($msg)  { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }
function LogOK($msg){ Write-Host "[$(Get-Date -Format 'HH:mm:ss')] OK: $msg" }
function LogW($msg) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] WARN: $msg" }
function LogE($msg) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ERROR: $msg" }

function Exec($exe, $argStr) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process $exe -ArgumentList $argStr -Wait -NoNewWindow -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $out = Get-Content $o -Raw -ErrorAction SilentlyContinue
    $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err }
}

Log "=== Juniper Inventory Native Setup ==="
Log "PS version: $($PSVersionTable.PSVersion)"
Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# ── PostgreSQL cluster init + service ─────────────────────────────────────────
Log ""; Log "==> Phase 1: PostgreSQL"

$pgSvc = Get-Service postgresql-x64-16 -ErrorAction SilentlyContinue
if (-not $pgSvc) {
    $initdb = "$pgBin\initdb.exe"
    if (Test-Path $initdb) {
        Log "PG binaries present, initializing cluster at $pgData ..."
        if (-not (Test-Path $pgData)) { New-Item $pgData -ItemType Directory -Force | Out-Null }
        $pwFile = [IO.Path]::GetTempFileName()
        Set-Content $pwFile $PgSuperPw -NoNewline
        $r = Exec $initdb "-D `"$pgData`" -U postgres -E UTF8 -A scram-sha-256 --pwfile=`"$pwFile`""
        Remove-Item $pwFile -ErrorAction SilentlyContinue
        Log "initdb exit: $($r.ExitCode)"
        if ($r.Out) { Log "initdb: $($r.Out.Trim())" }
        if ($r.Err) { LogW "initdb: $($r.Err.Trim())" }
    } else {
        Log "PG binaries missing, downloading installer..."
        $inst = "$env:TEMP\pg16.exe"
        (New-Object Net.WebClient).DownloadFile(
            'https://get.enterprisedb.com/postgresql/postgresql-16.6-1-windows-x64.exe', $inst)
        Log "Running PG installer (silent)..."
        $r = Exec $inst "--mode unattended --superpassword `"$PgSuperPw`" --servicename postgresql-x64-16 --datadir `"$pgData`" --prefix `"C:\Program Files\PostgreSQL\16`""
        Log "PG installer exit: $($r.ExitCode)"
        Remove-Item $inst -ErrorAction SilentlyContinue
    }

    # Register service with pg_ctl
    $pgctl = "$pgBin\pg_ctl.exe"
    if (Test-Path $pgctl) {
        Log "Registering service..."
        $r = Exec $pgctl "-D `"$pgData`" -N postgresql-x64-16 -o `"-p $PgPort`" register"
        Log "pg_ctl register exit: $($r.ExitCode) $(if($r.Err){$r.Err.Trim()})"
    }
} else {
    Log "PG service already exists: $($pgSvc.Status)"
}

$pgSvc = Get-Service postgresql-x64-16 -ErrorAction SilentlyContinue
if ($pgSvc -and $pgSvc.Status -ne 'Running') {
    Log "Starting postgresql-x64-16..."
    Start-Service postgresql-x64-16
    Start-Sleep 4
}
$pgSvc = Get-Service postgresql-x64-16 -ErrorAction SilentlyContinue
Log "PG service status: $(if($pgSvc){$pgSvc.Status}else{'NOT FOUND'})"

# ── Create role + database ─────────────────────────────────────────────────────
Log ""; Log "==> Phase 2: DB role + database"
$psql = "$pgBin\psql.exe"
if (Test-Path $psql) {
    $env:PGPASSWORD = $PgSuperPw
    $sql = "DO `$`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$PgUser') THEN CREATE ROLE $PgUser LOGIN PASSWORD '$DbPw'; ELSE ALTER ROLE $PgUser WITH PASSWORD '$DbPw'; END IF; END `$`$;"
    $r = Exec $psql "-U postgres -p $PgPort -c `"$sql`""
    Log "Create role exit: $($r.ExitCode)$(if($r.Err){' '+$r.Err.Trim()})"

    $r2 = Exec $psql "-U postgres -p $PgPort -tAc `"SELECT 1 FROM pg_database WHERE datname='$PgDb'`""
    $exists = if ($r2.Out) { $r2.Out.Trim() } else { '' }
    if ($exists -ne '1') {
        $r3 = Exec $psql "-U postgres -p $PgPort -c `"CREATE DATABASE $PgDb OWNER $PgUser ENCODING 'UTF8'`""
        Log "Create DB exit: $($r3.ExitCode)$(if($r3.Err){' '+$r3.Err.Trim()})"
    } else { Log "DB '$PgDb' already exists." }
    $env:PGPASSWORD = ''
} else { LogE "psql not found at $psql" }

# ── Python 3.12 ───────────────────────────────────────────────────────────────
Log ""; Log "==> Phase 3: Python 3.12"
if (-not (Test-Path $PyExe)) {
    $inst = "$env:TEMP\python312.exe"
    Log "Downloading Python 3.12.9 ..."
    (New-Object Net.WebClient).DownloadFile(
        'https://www.python.org/ftp/python/3.12.9/python-3.12.9-amd64.exe', $inst)
    Log "Installing Python 3.12 (silent)..."
    $r = Exec $inst "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=C:\Python312"
    Log "Python install exit: $($r.ExitCode)"
    Remove-Item $inst -ErrorAction SilentlyContinue
} else { Log "Python already at $PyExe" }

if (Test-Path $PyExe) {
    $r = Exec $PyExe "--version"; Log "Python: $(($r.Out+$r.Err).Trim())"
} else { LogE "Python not found at $PyExe" }

# ── NSSM ──────────────────────────────────────────────────────────────────────
Log ""; Log "==> Phase 4: NSSM"
if (-not (Test-Path $NssmExe)) {
    $nssmZip = "$env:TEMP\nssm.zip"
    Log "Downloading NSSM..."
    (New-Object Net.WebClient).DownloadFile('https://nssm.cc/release/nssm-2.24.zip', $nssmZip)
    Expand-Archive $nssmZip -DestinationPath "$env:TEMP\nssm_ext" -Force
    New-Item 'C:\nssm' -ItemType Directory -Force | Out-Null
    Copy-Item "$env:TEMP\nssm_ext\nssm-2.24\win64\nssm.exe" $NssmExe -Force
    Remove-Item $nssmZip,"$env:TEMP\nssm_ext" -Recurse -ErrorAction SilentlyContinue
    Log "NSSM installed."
} else { Log "NSSM already present." }

# ── App deployment ─────────────────────────────────────────────────────────────
Log ""; Log "==> Phase 5: App deployment"
if (-not (Test-Path $InstallRoot)) { New-Item $InstallRoot -ItemType Directory -Force | Out-Null }
if (Test-Path $AppSrc) {
    Copy-Item $AppSrc "$InstallRoot\app" -Recurse -Force
    Log "Copied app to $InstallRoot\app"
} else { LogE "App source not found: $AppSrc" }

# Patch main.py
$mainPy = "$InstallRoot\app\main.py"
if (Test-Path $mainPy) {
    $txt = Get-Content $mainPy -Raw
    if ($txt -notmatch 'import os') { $txt = "import os`n" + $txt }
    $txt = $txt -replace [regex]::Escape('Path("/app/exports")'), 'Path(os.environ.get("EXPORT_DIR", str(Path(__file__).parent.parent / "exports")))'
    Set-Content $mainPy $txt -Encoding UTF8
    Log "Patched main.py EXPORT_DIR"
} else { LogW "main.py not found at $mainPy" }

# Create venv
$venvPy = "$InstallRoot\venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    Log "Creating venv..."
    $r = Exec $PyExe "-m venv `"$InstallRoot\venv`""
    Log "venv exit: $($r.ExitCode)$(if($r.Err){' '+$r.Err.Trim()})"
} else { Log "venv exists." }

# pip install
$reqFile = "$InstallRoot\app\requirements.txt"
if (Test-Path $reqFile) {
    Log "Installing Python requirements (may take ~2 min)..."
    $pip = "$InstallRoot\venv\Scripts\pip.exe"
    $r = Exec $pip "install -r `"$reqFile`""
    Log "pip exit: $($r.ExitCode)$(if($r.ExitCode -ne 0 -and $r.Err){' '+$r.Err.Trim()})"
}

# Exports dir
$exp = "$InstallRoot\exports"
if (-not (Test-Path $exp)) { New-Item $exp -ItemType Directory -Force | Out-Null }

# ── Restore DB backup ──────────────────────────────────────────────────────────
if ($RestoreFrom -and (Test-Path $RestoreFrom)) {
    Log ""; Log "==> Phase 6: Restore DB from $RestoreFrom"
    $env:PGPASSWORD = $DbPw
    $r = Exec $psql "-U $PgUser -d $PgDb -p $PgPort -f `"$RestoreFrom`""
    Log "Restore exit: $($r.ExitCode)$(if($r.Err){' '+$r.Err.Trim()})"
    $env:PGPASSWORD = ''
}

# ── NSSM service ──────────────────────────────────────────────────────────────
Log ""; Log "==> Phase 7: Windows service"
$uvicorn = "$InstallRoot\venv\Scripts\uvicorn.exe"
$dbUrl   = "postgresql+psycopg://${PgUser}:${DbPw}@localhost:${PgPort}/${PgDb}"

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    $r = Exec $NssmExe "remove $ServiceName confirm"
    Log "Removed existing service: exit $($r.ExitCode)"
}

$r = Exec $NssmExe "install $ServiceName `"$uvicorn`""
Log "nssm install exit: $($r.ExitCode)"

$cfgs = @(
    "set $ServiceName AppParameters `"main:app --host 0.0.0.0 --port $Port`"",
    "set $ServiceName AppDirectory `"$InstallRoot\app`"",
    "set $ServiceName AppStdout `"$InstallRoot\uvicorn.log`"",
    "set $ServiceName AppStderr `"$InstallRoot\uvicorn-err.log`"",
    "set $ServiceName AppRotateFiles 1",
    "set $ServiceName AppRotateSeconds 86400",
    "set $ServiceName Start SERVICE_AUTO_START",
    "set $ServiceName DisplayName `"Juniper Design - Inventory Server`"",
    "set $ServiceName Description `"FastAPI inventory service (Juniper Design)`""
)
foreach ($cfg in $cfgs) {
    $r = Exec $NssmExe $cfg
    if ($r.ExitCode -ne 0) { LogW "nssm $cfg => $($r.ExitCode)" }
}

# Service env vars in registry (Admin/SYSTEM only)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$envStr  = "DATABASE_URL=$dbUrl`0EXPORT_DIR=$exp`0UNIFI_HOST=$UnifiHost`0UNIFI_USERNAME=$UnifiUser`0UNIFI_PASSWORD=$UnifiPw`0"
Set-ItemProperty -Path $regPath -Name Environment -Value $envStr -Force -ErrorAction SilentlyContinue
Log "Env vars stored in service registry."

# Firewall rule
Remove-NetFirewallRule -Name "JuniperInventory-$Port" -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -Name "JuniperInventory-$Port" -DisplayName "Juniper Inventory (port $Port)" `
    -Protocol TCP -LocalPort $Port -Direction Inbound -Action Allow | Out-Null
Log "Firewall rule created for TCP $Port."

# Start service
Start-Service $ServiceName -ErrorAction SilentlyContinue
Start-Sleep 5
$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
Log "Service status: $(if($svc){$svc.Status}else{'NOT FOUND'})"

# ── Verify ────────────────────────────────────────────────────────────────────
Log ""; Log "==> Phase 8: Verification"
Start-Sleep 5
try {
    $resp = Invoke-RestMethod "http://localhost:$Port/healthz" -TimeoutSec 10 -ErrorAction Stop
    LogOK "Health check passed: $($resp | ConvertTo-Json -Compress)"
} catch {
    try {
        $resp2 = Invoke-WebRequest "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        LogOK "Root endpoint responded HTTP $($resp2.StatusCode)"
    } catch {
        LogW "Health check failed: $_"
        if (Test-Path "$InstallRoot\uvicorn-err.log") {
            Log "--- Last 20 lines of uvicorn stderr ---"
            Get-Content "$InstallRoot\uvicorn-err.log" -Tail 20 | ForEach-Object { Log $_ }
        }
    }
}

Log ""; Log "=== Setup finished at $(Get-Date) ==="
