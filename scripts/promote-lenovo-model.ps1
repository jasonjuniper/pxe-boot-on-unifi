#Requires -Version 5.1
<#
promote-lenovo-model.ps1
--------------------------------------------------------------------------------
Final step of the Lenovo driver pipeline (after build-lenovo-manifest.ps1 ->
sync-lenovo-drivers.ps1 -> curate-lenovo-model.ps1).

Reads C:\deploy\_staging\<MT>_curate-results.json and, for every package that
yielded .inf files:
  1. renames the staged <Slug>-curated tree to the final <Slug> (archiving any
     existing <Slug> as <Slug>.old-<ts>),
  2. marks the matching driver_packages row confirmed_working, sets file_path to
     <Slug>\<subdir>\<name> and backfills the real SHA256 curate computed,
  3. regenerates manifest.json from the DB (confirmed_working) and writes it to
     C:\deploy\drivers\manifest.json so deploy.ps1 offline injection is current.

Packages with no .inf (pure firmware/apps) and the BIOS package are left
unconfirmed - they are not offline-injectable.

Usage (on pc-deploy):
    .\promote-lenovo-model.ps1 -MachineType 83JU -Slug lenovo-yoga-7-16akp10
--------------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $MachineType,
    [Parameter(Mandatory)] [string] $Slug,
    [string] $ApiBase = 'http://127.0.0.1:8080'
)
$ErrorActionPreference = 'Stop'

$resultsPath = "C:\deploy\_staging\${MachineType}_curate-results.json"
if (-not (Test-Path $resultsPath)) { throw "Curate results not found: $resultsPath (run curate-lenovo-model.ps1 first)." }
$rows = Get-Content $resultsPath -Raw | ConvertFrom-Json

# -- 1. Promote staged tree: <Slug>-curated -> <Slug> --------------------------
$curatedRoot = "C:\deploy\drivers\$Slug-curated"
$finalRoot   = "C:\deploy\drivers\$Slug"
if (Test-Path $curatedRoot) {
    if (Test-Path $finalRoot) {
        $bak = "$finalRoot.old-$(Get-Date -Format yyyyMMddHHmmss)"
        Write-Host "Archiving existing $finalRoot -> $bak" -ForegroundColor DarkYellow
        Move-Item $finalRoot $bak -Force
    }
    Move-Item $curatedRoot $finalRoot -Force
    Write-Host "Promoted staged tree -> $finalRoot" -ForegroundColor Green
} else {
    Write-Warning "No curated tree at $curatedRoot - assuming already promoted."
}

# -- 2. DB connection (same parse as sync-lenovo-drivers.ps1) -------------------
$nssm = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Parameters" -ErrorAction SilentlyContinue
if (-not $nssm) { throw "Cannot read NSSM registry - run on pc-deploy." }
$dbUrl = ($nssm.AppEnvironmentExtra -split "`n" | Where-Object { $_ -match '^DATABASE_URL=' }) -replace '^DATABASE_URL=',''
if ($dbUrl -notmatch '^postgresql\+?[^:]*://([^:]+):([^@]+)@([^:/]+)(?::(\d+))?/(.+)$') { throw "DATABASE_URL not parseable." }
$dbUser=$Matches[1]; $env:PGPASSWORD=$Matches[2]; $dbHost=$Matches[3]
$dbPort= if ($Matches[4]) { $Matches[4] } else { '5432' }; $dbName=$Matches[5]
$psql = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
function Invoke-SQL([string]$Sql) {
    $tmp = [IO.Path]::GetTempFileName() + '.sql'
    [IO.File]::WriteAllText($tmp, $Sql, [Text.Encoding]::UTF8)
    try { $o = & $psql -h $dbHost -p $dbPort -U $dbUser -d $dbName -f $tmp 2>&1
          if ($LASTEXITCODE -ne 0) { throw "psql error: $o" }; return $o }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Esc([string]$s) { if ($null -eq $s) { 'NULL' } else { "'" + ($s -replace "'","''") + "'" } }

# -- 3. Confirm the rows that produced .inf ------------------------------------
$confirmed = 0
foreach ($r in $rows) {
    if (($r.inf_count -gt 0) -and $r.curated_path) {
        $fp = $r.curated_path -replace [regex]::Escape("$Slug-curated"), $Slug
        $sql = "UPDATE driver_packages SET status='confirmed_working', " +
               "file_path=$(Esc $fp), sha256=$(Esc $r.actual_sha256), updated_at=now() " +
               "WHERE machine_type=$(Esc $MachineType) AND external_id=$(Esc $r.name);"
        Invoke-SQL $sql | Out-Null
        $confirmed++
    }
}
Write-Host "Marked $confirmed package(s) confirmed_working for $MachineType." -ForegroundColor Green

# -- 4. Regenerate manifest.json (DB-driven) + persist offline fallback ---------
try {
    Invoke-WebRequest "$ApiBase/api/drivers/manifest.json" -UseBasicParsing -TimeoutSec 90 `
        -OutFile 'C:\deploy\drivers\manifest.json'
    Write-Host "manifest.json regenerated -> C:\deploy\drivers\manifest.json" -ForegroundColor Green
} catch { Write-Warning "manifest.json regen failed: $_" }
