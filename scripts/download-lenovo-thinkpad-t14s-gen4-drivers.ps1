#Requires -Version 5.1
# Download drivers for lenovo-thinkpad-t14s-gen4
# Run directly on pc-deploy as SYSTEM (Scheduled Task)
# Progress logged to C:\deploy\drivers\lenovo-thinkpad-t14s-gen4\_download.log

$DriverRoot    = "C:\deploy\drivers\lenovo-thinkpad-t14s-gen4"
$ManifestPath  = "C:\deploy\scripts\21fe-driver-manifest.json"
$LogFile       = "$DriverRoot\_download.log"
$HashField     = "sha256"
$HashAlgo      = "SHA256"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Msg" | Tee-Object -FilePath $LogFile -Append
}

New-Item -ItemType Directory -Force -Path $DriverRoot | Out-Null

Write-Log "=== Starting driver download: lenovo-thinkpad-t14s-gen4 ==="

if (-not (Test-Path $ManifestPath)) { Write-Log "ERROR: Manifest not found at $ManifestPath"; exit 1 }

$packages = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$total = $packages.Count
$idx   = 0

foreach ($pkg in $packages) {
    $idx++
    $destDir  = Join-Path $DriverRoot $pkg.subdir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $destFile = Join-Path $destDir $pkg.filename
    $sizeMB   = [Math]::Round($pkg.size_bytes / 1MB, 1)
    $expected = $pkg.$HashField

    if (Test-Path $destFile) {
        $hash = (Get-FileHash $destFile -Algorithm $HashAlgo).Hash
        if ($hash -ieq $expected) {
            Write-Log "[$idx/$total] SKIP (verified) $($pkg.subdir)\$($pkg.filename)"
            continue
        }
        Write-Log "[$idx/$total] REHASH FAILED - re-downloading $($pkg.filename)"
        Remove-Item $destFile -Force
    }

    Write-Log "[$idx/$total] Downloading $($pkg.subdir)\$($pkg.filename) ($sizeMB MB) ..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($pkg.url, $destFile)
        $wc.Dispose()
        $hash = (Get-FileHash $destFile -Algorithm $HashAlgo).Hash
        if ($hash -ieq $expected) {
            Write-Log "[$idx/$total] OK  $($pkg.filename)  $HashAlgo verified"
        } else {
            Write-Log "[$idx/$total] WARN: $HashAlgo mismatch for $($pkg.filename)"
        }
    } catch {
        Write-Log "[$idx/$total] ERROR: $_"
    }
}

Write-Log "=== Download complete: lenovo-thinkpad-t14s-gen4 ==="
