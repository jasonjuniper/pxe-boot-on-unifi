# 08-download-isos.ps1
# Downloads Windows 10 and 11 ISOs directly from Microsoft using Fido,
# then extracts install.wim into C:\deploy\images\ for PXE deployment.
#
# Fido (github.com/pbatard/Fido) is the standard tool for automating
# Microsoft's ISO download flow. It handles the session/token dance that
# the download page requires.
#
# Runtime: 30-90 min depending on internet speed (ISOs are ~5-6 GB each).
# Log: C:\iso-download.log
#
# USAGE: .\08-download-isos.ps1
#        .\08-download-isos.ps1 -SkipWin10   # skip Windows 10

param(
    [switch]$SkipWin10,
    [switch]$SkipWin11,
    [string]$IsoDir    = 'C:\ISOs',
    [string]$ImagesDir = 'C:\deploy\images'
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\iso-download.log' -Append

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  Juniper Design - Windows ISO Download' -ForegroundColor Cyan
Write-Host "  Started: $(Get-Date)" -ForegroundColor Cyan
Write-Host ('=' * 60)
Write-Host ''

New-Item $IsoDir    -ItemType Directory -Force | Out-Null
New-Item $ImagesDir -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Download Fido
# ---------------------------------------------------------------------------
$fidoPath = "$env:TEMP\Fido.ps1"
Write-Host '==> Downloading Fido...' -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://github.com/pbatard/Fido/raw/master/Fido.ps1' `
                  -OutFile $fidoPath -UseBasicParsing
Write-Host '  Fido ready.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# Helper: get URL, download ISO, extract WIM
# ---------------------------------------------------------------------------
function Get-WindowsImage {
    param(
        [string]$WinVer,     # '11' or '10'
        [string]$Release,    # '24H2', '22H2', etc.
        [string]$WimName     # 'win11.wim' or 'win10.wim'
    )

    $isoPath = "$IsoDir\$WimName.iso"
    $wimPath  = "$ImagesDir\$WimName"

    if (Test-Path $wimPath) {
        Write-Host "  $WimName already exists in $ImagesDir - skipping download." -ForegroundColor Green
        return $true
    }

    Write-Host ''
    Write-Host "==> Getting Windows $WinVer $Release download URL via Fido..." -ForegroundColor Cyan
    try {
        $url = & powershell.exe -ExecutionPolicy Bypass -File $fidoPath `
                   -Win $WinVer -Rel $Release -Ed "Pro" -Lang "English" -Arch "x64" -GetUrl 2>&1 |
               Where-Object { $_ -match '^https://' } |
               Select-Object -Last 1

        if (-not $url) { throw "Fido returned no URL" }
        Write-Host "  URL obtained." -ForegroundColor Green
        Write-Host "  (URL not logged per secrets policy)"
    } catch {
        Write-Host "  ERROR getting URL: $_" -ForegroundColor Red
        return $false
    }

    Write-Host "==> Downloading Windows $WinVer $Release ISO to $isoPath..." -ForegroundColor Cyan
    Write-Host '  This will take a while (~5 GB). Progress logged below.'
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $isoPath)
        $sizeGB = [math]::Round((Get-Item $isoPath).Length / 1073741824, 1)
        Write-Host "  Download complete: $sizeGB GB" -ForegroundColor Green
    } catch {
        Write-Host "  Download failed: $_" -ForegroundColor Red
        Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "==> Mounting ISO and extracting install.wim..." -ForegroundColor Cyan
    try {
        $mount  = Mount-DiskImage -ImagePath $isoPath -PassThru
        $letter = ($mount | Get-Volume).DriveLetter
        $src    = "${letter}:\sources\install.wim"

        Write-Host "  WIM indexes:"
        & dism /Get-WimInfo /WimFile:"$src"

        Write-Host "  Copying $src -> $wimPath ..."
        Copy-Item $src $wimPath -Force
        $sizeGB = [math]::Round((Get-Item $wimPath).Length / 1073741824, 1)
        Write-Host "  $WimName ready ($sizeGB GB)." -ForegroundColor Green
    } catch {
        Write-Host "  WIM extract failed: $_" -ForegroundColor Red
        return $false
    } finally {
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
    }

    # Keep the ISO in C:\ISOs in case it's needed again
    Write-Host "  ISO kept at $isoPath for future use."
    return $true
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
$results = @{}

if (-not $SkipWin11) {
    $results['Windows 11'] = Get-WindowsImage -WinVer '11' -Release '24H2' -WimName 'win11.wim'
}

if (-not $SkipWin10) {
    $results['Windows 10'] = Get-WindowsImage -WinVer '10' -Release '22H2' -WimName 'win10.wim'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  ISO DOWNLOAD SUMMARY' -ForegroundColor Cyan
Write-Host "  Finished: $(Get-Date)" -ForegroundColor Cyan
Write-Host ('=' * 60)

foreach ($k in $results.Keys) {
    if ($results[$k]) {
        Write-Host "  [OK]     $k" -ForegroundColor Green
    } else {
        Write-Host "  [FAILED] $k" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Images ready in: $ImagesDir" -ForegroundColor Cyan
Write-Host ''

Stop-Transcript
