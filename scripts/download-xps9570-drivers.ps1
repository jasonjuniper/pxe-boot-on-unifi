#Requires -Version 5.1
# Download Dell XPS 15 9570 drivers to deploy share
# Parsed from Dell CatalogPC.xml, systemID 087C (XPS 15 9570)
# Run directly on pc-deploy. Progress logged to C:\deploy\drivers\dell-xps-15-9570\_download.log
#
# NOTE: BIOS updates are NOT included - Dell's CatalogPC.xml does not publish
# XPS consumer BIOS in the enterprise catalog. Download BIOS manually from
# https://www.dell.com/support/home/product-support/product/xps-15-9570-laptop
# and place it in C:\deploy\drivers\dell-xps-15-9570\bios\

$DriverRoot = "C:\deploy\drivers\dell-xps-15-9570"
$ManifestPath = "C:\deploy\scripts\xps9570-driver-manifest.json"
$LogFile = "$DriverRoot\_download.log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Msg" | Tee-Object -FilePath $LogFile -Append
}

New-Item -ItemType Directory -Force -Path $DriverRoot | Out-Null

Write-Log "=== Starting XPS 15 9570 driver download ==="

if (-not (Test-Path $ManifestPath)) {
    Write-Log "ERROR: Manifest not found at $ManifestPath"
    exit 1
}

$packages = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$total = $packages.Count
$idx = 0

foreach ($pkg in $packages) {
    $idx++
    $destDir = Join-Path $DriverRoot $pkg.subdir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $destFile = Join-Path $destDir $pkg.filename
    $sizeMB = [Math]::Round($pkg.size_bytes / 1MB, 1)

    if (Test-Path $destFile) {
        # Verify existing file MD5 (Dell uses MD5, not SHA256)
        $hash = (Get-FileHash $destFile -Algorithm MD5).Hash
        if ($hash -ieq $pkg.md5) {
            Write-Log "[$idx/$total] SKIP (exists+verified) $($pkg.subdir)\$($pkg.filename)"
            continue
        } else {
            Write-Log "[$idx/$total] REHASH FAILED - re-downloading $($pkg.filename)"
            Remove-Item $destFile -Force
        }
    }

    Write-Log "[$idx/$total] Downloading $($pkg.subdir)\$($pkg.filename) ($sizeMB MB) ..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($pkg.url, $destFile)
        $wc.Dispose()

        # Verify MD5
        $hash = (Get-FileHash $destFile -Algorithm MD5).Hash
        if ($hash -ieq $pkg.md5) {
            Write-Log "[$idx/$total] OK  $($pkg.filename)  MD5 verified"
        } else {
            Write-Log "[$idx/$total] WARN: MD5 mismatch for $($pkg.filename) - expected $($pkg.md5) got $hash"
        }
    } catch {
        Write-Log "[$idx/$total] ERROR downloading $($pkg.filename): $_"
    }
}

Write-Log "=== Download complete ==="
