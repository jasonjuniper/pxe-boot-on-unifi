<#
  discover-drivers.ps1  -  vendor driver-discovery worker for the deployment hold/resume flow.
  Launched (detached) by the inventory server (_kick_driver_discovery) when a machine PXE-boots
  a model with no catalog drivers. Reports progress to POST /ingest/driver-job-update; the deploy
  resumes when the model has confirmed_working drivers (deploy.ps1 polls /api/drivers/ready).

  PHASE 1 (this file): serialize via a lock (never compete with an active WIM stream), and
  auto-REGISTER drivers that are already extracted on disk but uncataloged (the Dell XPS 13 9380
  case). PHASE 2 (TODO): implement the per-vendor DOWNLOAD pipelines (Dell CatalogPC/driver pack,
  Lenovo serial->machine-type->catalog->curate, HP CMSL) where nothing is on disk yet.
#>
param([int]$JobId, [string]$Manufacturer, [string]$Model, [string]$MachineType, [string]$Os, [string]$Serial)
$ErrorActionPreference = 'Continue'
$inv = 'http://127.0.0.1:8080'

function Report($state, $msg, $found) {
  $b = @{ job_id = $JobId; state = $state }
  if ($msg) { $b.message = $msg }
  if ($null -ne $found) { $b.drivers_found = [int]$found }
  try { Invoke-RestMethod -Method POST -Uri "$inv/ingest/driver-job-update" -Body ($b | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 15 | Out-Null } catch {}
}
function Slug($mfr, $mdl) {
  $k = if ($mfr) { "$mfr-$mdl" } else { $mdl }
  $k = ($k -replace '[^A-Za-z0-9]', '-'); $k = ($k -replace '-{2,}', '-').Trim('-')
  return $k.ToLower()
}
function Register-OnDisk($mdl, $mfr, $slug) {
  $py = 'C:\inventory\venv\Scripts\python.exe'
  $env:REG_MODEL = $mdl; $env:REG_MFR = $mfr; $env:REG_SLUG = $slug
  $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory\Parameters'
  $env:INV_DBURL = (((Get-ItemProperty $p).AppEnvironmentExtra | Where-Object { $_ -like 'DATABASE_URL=*' }) -replace '^DATABASE_URL=','')
  $code = @'
import os,psycopg
u=os.environ["INV_DBURL"].replace("postgresql+psycopg://","postgresql://")
mdl=os.environ["REG_MODEL"];mfr=os.environ["REG_MFR"] or None;slug=os.environ["REG_SLUG"]
root=r"C:\deploy\drivers";mdir=os.path.join(root,slug)
CAT={"net":"Network","network":"Network","wifi":"WiFi","wireless":"WiFi","bt":"Bluetooth","bluetooth":"Bluetooth","audio":"Audio","audio-realtek":"Audio","video":"Display","display":"Display","graphics":"Display","chipset":"Chipset","heci":"Chipset","serial-io":"Chipset","thunderbolt":"Chipset","storage":"Storage","rst":"Storage","fingerprint":"Fingerprint","camera":"Camera","input":"Keyboard"}
c=psycopg.connect(u);cur=c.cursor();ins=0
for dp,_,files in os.walk(mdir):
    for f in files:
        if not f.lower().endswith(".inf"):continue
        full=os.path.join(dp,f);rel=full[len(root)+1:];parts=rel.split("\\");sub=parts[1] if len(parts)>2 else "misc"
        cat=CAT.get(sub.lower(),"Other")
        cur.execute("select 1 from driver_packages where file_path=%s",(rel,))
        if cur.fetchone():continue
        cur.execute("insert into driver_packages (model,manufacturer,category,driver_name,os,file_path,file_size,status,status_set_by,status_set_at,added_by,created_at,updated_at) values (%s,%s,%s,%s,NULL,%s,%s,'confirmed_working','discover-drivers',now(),'discover-drivers',now(),now())",(mdl,mfr,cat,f,rel,os.path.getsize(full)))
        ins+=1
c.commit()
cur.execute("select count(*) from driver_packages where lower(model)=lower(%s) and status='confirmed_working'",(mdl,))
print(cur.fetchone()[0])
c.close()
'@
  Set-Content "$env:TEMP\reg_$JobId.py" $code -Encoding UTF8
  $out = & $py "$env:TEMP\reg_$JobId.py" 2>&1
  Remove-Item "$env:TEMP\reg_$JobId.py" -Force -ErrorAction SilentlyContinue
  return ($out | Select-Object -Last 1)
}

function Resolve-DellPack($model, $osHint) {
  # Parse Dell's DriverPackCatalog to find the driver-pack for this model (x64). Returns
  # @{url; format; version; file} or $null. Catalog cached 7 days.
  $cw = 'C:\deploy\_dl\dellcat'; New-Item -ItemType Directory -Force $cw | Out-Null
  $cab = "$cw\DriverPackCatalog.cab"; $xml = "$cw\DriverPackCatalog.xml"
  if ((-not (Test-Path $cab)) -or ((Get-Date) - (Get-Item $cab).LastWriteTime).TotalDays -gt 7) {
    & curl.exe -L --fail -s -o $cab 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
    Remove-Item $xml -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path $xml)) { & expand.exe $cab $xml | Out-Null }
  if ((-not (Test-Path $xml)) -or (Get-Item $xml).Length -lt 1000) { return $null }
  [xml]$cat = Get-Content $xml -Raw
  $ns = New-Object System.Xml.XmlNamespaceManager($cat.NameTable); $ns.AddNamespace('d', $cat.DocumentElement.NamespaceURI)
  $osPref = if ($osHint -match '11') { 'Windows11' } elseif ($osHint -match '10') { 'Windows10' } else { 'Windows11' }
  $cands = @()
  foreach ($pk in $cat.SelectNodes('//d:DriverPackage', $ns)) {
    $mnames = @($pk.SelectNodes('.//d:Model', $ns) | ForEach-Object { "$($_.name)".Trim() })
    if (-not ($mnames | Where-Object { $_ -and $_ -ieq $model.Trim() })) { continue }
    $x64 = @($pk.SelectNodes('.//d:OperatingSystem', $ns) | Where-Object { $_.osArch -eq 'x64' })
    if (-not $x64) { continue }
    $cands += [pscustomobject]@{ path=$pk.path; format=$pk.format; ver=$pk.dellVersion; osCodes=@($x64|ForEach-Object{$_.osCode}); date=$pk.dateTime }
  }
  if (-not $cands) { return $null }
  $best = $cands | Sort-Object @{E={ if ($_.osCodes -contains $osPref) {0} else {1} }}, @{E={$_.date}; Descending=$true} | Select-Object -First 1
  return @{ url = 'https://downloads.dell.com/' + $best.path; format = $best.format; version = $best.ver; file = (Split-Path $best.path -Leaf) }
}

$lock = 'C:\deploy\drivers\_discovery.lock'
$haveLock = $false
try {
  # break a stale lock (>45 min) from a crashed prior run
  if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -gt 45) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 90 -and -not $haveLock; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None'); $fs.Close(); $haveLock = $true }
    catch { Start-Sleep -Seconds 10 }
  }
  Report 'discovering' "Resolving drivers for $Manufacturer $Model" $null

  $slug = Slug $Manufacturer $Model
  $dir  = "C:\deploy\drivers\$slug"

  # (1) drivers already extracted on disk but uncataloged -> register them (the 9380 case)
  if ((Test-Path $dir) -and (Get-ChildItem $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)) {
    Report 'downloading' "Drivers already on disk ($slug); registering into catalog..." $null
    $cnt = Register-OnDisk $Model $Manufacturer $slug
    if ([int]$cnt -gt 0) { Report 'ready' "Registered on-disk drivers ($cnt confirmed_working)" ([int]$cnt); return }
  }

  # (2) nothing on disk -> vendor DOWNLOAD pipeline (PHASE 2 - to implement)
  $mfrL = ($Manufacturer + '').ToLower()
  if ($mfrL -match 'dell') {
    Report 'downloading' "Dell: resolving driver pack for '$Model'..." $null
    $pk = Resolve-DellPack $Model $Os
    if (-not $pk) { Report 'failed' "No Dell driver pack found for model '$Model' (x64)." 0; return }
    $dl = "C:\deploy\_dl\$slug"; New-Item -ItemType Directory -Force $dl | Out-Null
    $pf = "$dl\$($pk.file)"
    Report 'downloading' "Dell: downloading pack $($pk.file) (v$($pk.version))..." $null
    & curl.exe -L --fail -s -o $pf $pk.url
    if (-not (Test-Path $pf)) { Report 'failed' "Dell pack download failed: $($pk.url)" 0; return }
    $dest = "C:\deploy\drivers\$slug"; New-Item -ItemType Directory -Force $dest | Out-Null
    Report 'downloading' "Dell: extracting pack to $slug..." $null
    if (($pk.format -eq 'cab') -or ($pf -match '\.cab$')) { & expand.exe "$pf" -F:* "$dest" | Out-Null }
    else { Start-Process $pf -ArgumentList '/s', "/e=$dest" -Wait }
    Remove-Item $pf -Force -ErrorAction SilentlyContinue   # reclaim the ~1GB pack after extract
    $cnt = Register-OnDisk $Model $Manufacturer $slug
    if ([int]$cnt -gt 0) { Report 'ready' "Dell pack extracted + registered ($cnt drivers) v$($pk.version)" ([int]$cnt) }
    else { Report 'failed' "Dell pack extracted but no .inf found under $slug" 0 }
    return
  }
  elseif ($mfrL -match 'lenovo') {
    $mt = ("$MachineType").Trim()
    if (-not $mt -and $Serial) {
      try {
        $r = Invoke-RestMethod "https://pcsupport.lenovo.com/us/en/api/v4/mse/getproducts?productId=$Serial" -TimeoutSec 20
        $mm = [regex]::Matches(($r | ConvertTo-Json -Depth 8), '\b(2[0-9][A-Z0-9]{2}|8[0-9][A-Z0-9]{2})\b')
        if ($mm.Count) { $mt = $mm[0].Groups[1].Value }
      } catch {}
    }
    if (-not $mt) { Report 'failed' "Lenovo: could not resolve machine type (serial='$Serial')." 0; return }
    $osTag = if ($Os -match '10') { 'Win10' } else { 'Win11' }
    Report 'downloading' "Lenovo: building driver manifest for $mt ($osTag)..." $null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\deploy\scripts\build-lenovo-manifest.ps1' -MachineType $mt -Os $osTag *> $null
    $mf = "C:\deploy\scripts\$mt-driver-manifest.json"; if (-not (Test-Path $mf)) { $mf = "C:\deploy\scripts\$($mt.ToLower())-driver-manifest.json" }
    if (-not (Test-Path $mf)) { Report 'failed' "Lenovo: manifest build failed for $mt." 0; return }
    Report 'downloading' "Lenovo: downloading + extracting SoftPaqs for $mt (BIOS/firmware skipped)..." $null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\deploy\scripts\curate-lenovo-model.ps1' -MachineType $mt -Slug $slug *> $null
    $curated = "C:\deploy\drivers\$slug-curated"
    if ((Test-Path $curated) -and (Get-ChildItem $curated -Recurse -Filter *.inf -ErrorAction SilentlyContinue)) {
      New-Item -ItemType Directory -Force "C:\deploy\drivers\$slug" | Out-Null
      Copy-Item "$curated\*" "C:\deploy\drivers\$slug" -Recurse -Force
      $cnt = Register-OnDisk $Model $Manufacturer $slug
      if ([int]$cnt -gt 0) { Report 'ready' "Lenovo $mt curated + registered ($cnt drivers)" ([int]$cnt); return }
    }
    Report 'failed' "Lenovo: no .inf drivers curated for $mt." 0; return
  }
  elseif ($mfrL -match 'hp|hewlett') {
    $plat = ("$MachineType").Trim().ToUpper()   # HP platform id = Win32_BaseBoard.Product; deploy.ps1 sends it as machine_type
    if (-not $plat) { Report 'failed' "HP: no platform id (Win32_BaseBoard.Product) provided." 0; return }
    $osF = if ($Os -match '10') { 'win10_64' } else { 'win11_64' }
    $mf = "C:\deploy\scripts\hp-$($plat.ToLower())-manifest.json"
    Report 'downloading' "HP: fetching SoftPaq catalog for platform $plat..." $null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\deploy\scripts\fetch-hp-catalog.ps1' -PlatformId $plat -Model $Model -OsFilter $osF -OutFile $mf *> $null
    if (-not (Test-Path $mf)) { Report 'failed' "HP: catalog fetch failed for platform $plat." 0; return }
    $pkgs = Get-Content $mf -Raw | ConvertFrom-Json
    $dest = "C:\deploy\drivers\$slug"; $dl = "C:\deploy\_dl\$slug"
    New-Item -ItemType Directory -Force $dest, $dl | Out-Null
    Report 'downloading' "HP: downloading $($pkgs.Count) SoftPaqs for $plat (BIOS/firmware skipped)..." $null
    foreach ($pkg in $pkgs) {
      if (("$($pkg.category)") -match '(?i)bios|firmware') { continue }
      $url = $pkg.url; if (-not $url) { continue }
      $exe = Join-Path $dl ("$($pkg.filename)"); if (-not $pkg.filename) { $exe = Join-Path $dl (Split-Path $url -Leaf) }
      & curl.exe -L --fail -s -o $exe $url
      if (Test-Path $exe) {
        $subName = ("$($pkg.subdir)") -replace '[^A-Za-z0-9\-]', '-'; if (-not $subName) { $subName = 'sp' }
        $sub = Join-Path $dest $subName; New-Item -ItemType Directory -Force $sub | Out-Null
        Start-Process $exe -ArgumentList '-s', '-e', "-f`"$sub`"" -Wait -ErrorAction SilentlyContinue
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
      }
    }
    $cnt = Register-OnDisk $Model $Manufacturer $slug
    if ([int]$cnt -gt 0) { Report 'ready' "HP $plat downloaded + registered ($cnt drivers)" ([int]$cnt); return }
    Report 'failed' "HP: no .inf drivers extracted for platform $plat." 0; return
  }
  else { Report 'failed' "No pipeline for manufacturer '$Manufacturer'." 0 }
}
catch { Report 'failed' "discover-drivers exception: $($_.Exception.Message)" 0 }
finally { if ($haveLock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue } }
