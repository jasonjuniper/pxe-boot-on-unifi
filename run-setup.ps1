# run-setup.ps1
# Overnight setup runner — executes the remaining imaging server setup steps
# with full logging. Deploy to pc-deploy and run as a scheduled task.
#
# STEPS:
#   1. Build custom WinPE image + install tftpd64 (01c-build-winpe.ps1)
#   2. Create deploy$ share + populate scripts/unattend (01d-setup-deploy-share.ps1)
#   3. Copy Windows WIM files if ISOs are found in common locations
#
# LOGS: C:\deploy-setup.log  (appended)
#       C:\deploy-setup-summary.txt  (overwritten — human-readable result)

$ErrorActionPreference = 'Continue'

$LogFile     = 'C:\deploy-setup.log'
$SummaryFile = 'C:\deploy-setup-summary.txt'
$ScriptRoot  = Split-Path $MyInvocation.MyCommand.Path -Parent

Start-Transcript -Path $LogFile -Append

$startTime = Get-Date
$results   = [ordered]@{}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "  Juniper Design PC Imaging Server — Overnight Setup" -ForegroundColor Cyan
Write-Host "  Started: $startTime" -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ''

# ─── Helper ────────────────────────────────────────────────────────────────────

function Run-Step {
    param([string]$Name, [scriptblock]$Block)
    Write-Host ''
    Write-Host ">>> $Name" -ForegroundColor Yellow
    Write-Host ('-' * 50)
    try {
        & $Block
        $results[$Name] = 'SUCCESS'
        Write-Host "<<< $Name : SUCCESS" -ForegroundColor Green
    } catch {
        $results[$Name] = "FAILED: $_"
        Write-Host "<<< $Name : FAILED" -ForegroundColor Red
        Write-Host "    $_" -ForegroundColor Red
    }
}

# ─── Step 1: Build WinPE ───────────────────────────────────────────────────────

Run-Step '01c-build-winpe' {
    $script = Join-Path $ScriptRoot 'scripts\01c-build-winpe.ps1'
    if (-not (Test-Path $script)) { throw "Script not found: $script" }
    & $script
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

# ─── Step 2: Deploy share ──────────────────────────────────────────────────────

Run-Step '01d-setup-deploy-share' {
    $script = Join-Path $ScriptRoot 'scripts\01d-setup-deploy-share.ps1'
    if (-not (Test-Path $script)) { throw "Script not found: $script" }
    & $script
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

# ─── Step 3: Copy WIM files ────────────────────────────────────────────────────

Run-Step 'Copy WIM files' {
    $ImagesDir = 'C:\deploy\images'
    New-Item $ImagesDir -ItemType Directory -Force | Out-Null

    # Locations to search for .iso files
    $isoSearchPaths = @(
        'C:\ISOs', 'C:\iso', 'C:\Images',
        'D:\', 'D:\ISOs', 'D:\iso',
        'E:\', 'E:\ISOs',
        "$env:USERPROFILE\Downloads"
    )
    $isoFiles = $isoSearchPaths |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Filter '*.iso' -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -match 'win(dows)?(10|11)' }

    # Also check optical drives
    $drives = Get-PSDrive -PSProvider FileSystem |
              Where-Object { $_.Root -match '^[D-Z]:\\' -and (Test-Path "$($_.Root)sources\install.wim") }

    $copied = @()

    foreach ($iso in $isoFiles) {
        $ver = if ($iso.Name -match '11') { 'win11' } else { 'win10' }
        $dest = "$ImagesDir\$ver.wim"
        if (Test-Path $dest) { Write-Host "  Exists: $dest — skipping"; $copied += $ver; continue }

        Write-Host "  Mounting $($iso.FullName)..."
        $mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
        $letter = ($mount | Get-Volume).DriveLetter
        $src = "${letter}:\sources\install.wim"

        if (Test-Path $src) {
            Write-Host "  Checking WIM indexes on $src ..."
            & dism /Get-WimInfo /WimFile:"$src"
            Write-Host "  Copying $src -> $dest (this may take a few minutes)..."
            Copy-Item $src $dest -Force
            Write-Host "  Copied $ver.wim ($([math]::Round((Get-Item $dest).Length/1GB,1)) GB)." -ForegroundColor Green
            $copied += $ver
        } else {
            Write-Host "  WARN: No install.wim found in mounted ISO $($iso.Name)" -ForegroundColor Yellow
        }
        Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
    }

    foreach ($drv in $drives) {
        $src  = "$($drv.Root)sources\install.wim"
        # Determine win10 vs win11 by checking WIM info
        $info = & dism /Get-WimInfo /WimFile:"$src" 2>$null | Out-String
        $ver  = if ($info -match 'Windows 11') { 'win11' } elseif ($info -match 'Windows 10') { 'win10' } else { 'windows' }
        $dest = "$ImagesDir\$ver.wim"
        if (Test-Path $dest) { Write-Host "  Exists: $dest — skipping"; $copied += $ver; continue }
        Write-Host "  Copying from optical drive $($drv.Root) -> $dest ..."
        Copy-Item $src $dest -Force
        Write-Host "  Copied $ver.wim." -ForegroundColor Green
        $copied += $ver
    }

    if ($copied.Count -eq 0) {
        Write-Host ''
        Write-Host '  No Windows ISOs found automatically.' -ForegroundColor Yellow
        Write-Host '  WIM files must be copied manually:' -ForegroundColor Yellow
        Write-Host "    dism /Get-WimInfo /WimFile:D:\sources\install.wim"
        Write-Host "    copy D:\sources\install.wim $ImagesDir\win11.wim"
        Write-Host '  (Mount ISO first if needed: Mount-DiskImage -ImagePath <path>)'
        $results['Copy WIM files'] = 'SKIPPED — no ISOs found; manual copy required'
        # Don't throw — this isn't a fatal failure; the server is otherwise ready
    } else {
        Write-Host "  WIM files copied: $($copied -join ', ')" -ForegroundColor Green
    }
}

# ─── Summary ───────────────────────────────────────────────────────────────────

$endTime = Get-Date
$elapsed = [math]::Round(($endTime - $startTime).TotalMinutes, 1)

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  SETUP SUMMARY' -ForegroundColor Cyan
Write-Host "  Completed: $endTime  (${elapsed} min)" -ForegroundColor Cyan
Write-Host ('=' * 60)

$summaryLines = @(
    "Juniper Design PC Imaging Server — Setup Results",
    "Started : $startTime",
    "Finished: $endTime  ($elapsed min)",
    ""
)

$allOk = $true
foreach ($step in $results.Keys) {
    $status = $results[$step]
    $icon   = if ($status -eq 'SUCCESS') { '[OK]    ' } elseif ($status -like 'SKIPPED*') { '[SKIP]  ' } else { '[FAILED]' }
    $color  = if ($status -eq 'SUCCESS') { 'Green' } elseif ($status -like 'SKIPPED*') { 'Yellow' } else { 'Red' }
    Write-Host "  $icon $step" -ForegroundColor $color
    if ($status -ne 'SUCCESS') { Write-Host "          $status" -ForegroundColor $color; $allOk = $false }
    $summaryLines += "$icon $step"
    if ($status -ne 'SUCCESS') { $summaryLines += "         $status" }
}

$summaryLines += ""
if ($allOk) {
    $summaryLines += "RESULT: ALL STEPS SUCCEEDED"
    Write-Host ''
    Write-Host '  ALL STEPS SUCCEEDED' -ForegroundColor Green
} else {
    $summaryLines += "RESULT: ONE OR MORE STEPS NEED ATTENTION (see above)"
    Write-Host ''
    Write-Host '  ONE OR MORE STEPS NEED ATTENTION — see log for details.' -ForegroundColor Yellow
}

$summaryLines += ""
$summaryLines += "NEXT (manual) STEPS:"
$summaryLines += "  - If WIM copy was skipped: mount Windows ISO and run:"
$summaryLines += "      dism /Get-WimInfo /WimFile:D:\sources\install.wim"
$summaryLines += "      copy D:\sources\install.wim C:\deploy\images\win11.wim"
$summaryLines += "  - Verify Ubiquiti DHCP option 67 = boot\bootmgfw.efi"
$summaryLines += "  - PXE-boot a test machine to validate the deploy menu"
$summaryLines += ""
$summaryLines += "Full log: $LogFile"

$summaryLines | Set-Content $SummaryFile -Encoding UTF8
Write-Host ''
Write-Host "  Summary written to: $SummaryFile" -ForegroundColor Cyan
Write-Host "  Full log at       : $LogFile" -ForegroundColor Cyan
Write-Host ''

Stop-Transcript
