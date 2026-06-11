# 01d-setup-deploy-share.ps1
# Creates C:\deploy on pc-deploy, shares it as deploy$ (Everyone:Read),
# and sets up the expected directory structure.
#
# The WinPE deploy.ps1 connects to \\192.168.5.141\deploy$ (no credentials)
# to read WIM images, unattend files, and post-install scripts.
#
# WHY Everyone:Read on a hidden share?
#   WinPE has no domain membership and no local accounts to authenticate with.
#   The deploy$ share holds no secrets — all secrets are in 1Password and
#   retrieved at runtime via 'op read' AFTER Windows is installed.
#   Windows ISOs are publicly available, and unattend files contain only
#   organizational settings (no passwords, keys, or PSKs).
#
# USAGE: .\01d-setup-deploy-share.ps1
#        .\01d-setup-deploy-share.ps1 -DeployRoot D:\deploy

param(
    [string]$DeployRoot = 'C:\deploy',
    [string]$ShareName  = 'deploy$'
)

$ErrorActionPreference = 'Stop'

# ─── Create directories ────────────────────────────────────────────────────────
Write-Host "==> Creating deploy folder structure under $DeployRoot" -ForegroundColor Cyan

$dirs = @(
    $DeployRoot,
    "$DeployRoot\images",     # WIM files (win11.wim, win10.wim)
    "$DeployRoot\unattend",   # unattend-win11.xml, unattend-win10.xml
    "$DeployRoot\scripts",    # 03-09 post-install scripts
    "$DeployRoot\packages",   # MSI/EXE installers
    "$DeployRoot\winpe",      # optional: source copies of startnet.cmd + deploy.ps1
    "$DeployRoot\drivers"     # driver packs per model — see drivers\manifest.json
)

foreach ($d in $dirs) {
    if (Test-Path $d) {
        Write-Host "  Exists: $d" -ForegroundColor DarkGray
    } else {
        New-Item -Path $d -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $d" -ForegroundColor Green
    }
}

# ─── Create / update share ─────────────────────────────────────────────────────
Write-Host ''
Write-Host "==> Configuring share: $ShareName" -ForegroundColor Cyan

$existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Share already exists. Verifying permissions..."
    Remove-SmbShare -Name $ShareName -Force
}

New-SmbShare -Name $ShareName -Path $DeployRoot `
             -Description 'Juniper Design PC Deployment Share (read-only)' `
             -FullAccess 'SYSTEM','Administrators' | Out-Null

# Everyone:Read on the share (NTFS permissions also apply; default NTFS allows read)
Grant-SmbShareAccess -Name $ShareName -AccountName 'Everyone' `
                     -AccessRight Read -Force | Out-Null

Write-Host "  Share created: \\$(hostname)\$ShareName -> $DeployRoot" -ForegroundColor Green
Write-Host '  Permissions: SYSTEM + Administrators (Full), Everyone (Read)' -ForegroundColor DarkGray

# ─── Copy scripts and unattend files from this repo ───────────────────────────
Write-Host ''
Write-Host '==> Populating share with scripts and unattend files' -ForegroundColor Cyan

# Find repo root (this script is in scripts\)
$repoRoot = Split-Path $PSScriptRoot -Parent

$scriptsToCopy = @('deploy.ps1',
                   '03-windows-update.ps1','04-install-packages.ps1',
                   '05-install-drivers.ps1',
                   '05-setup-printers.ps1','06-join-wifi.ps1','07-remove-bloatware.ps1',
                   '09-update-driver-warehouse.ps1',
                   'setup-inventory-native.ps1')
foreach ($s in $scriptsToCopy) {
    $src = Join-Path $repoRoot "scripts\$s"
    $dst = "$DeployRoot\scripts\$s"
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "  Copied: scripts\$s" -ForegroundColor Green
    } else {
        Write-Host "  WARN: Not found: $src (skipped)" -ForegroundColor Yellow
    }
}

$unattendToCopy = @('unattend-win11.xml','unattend-win10.xml')
foreach ($u in $unattendToCopy) {
    $src = Join-Path $repoRoot "unattend\$u"
    $dst = "$DeployRoot\unattend\$u"
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "  Copied: unattend\$u" -ForegroundColor Green
    } else {
        Write-Host "  WARN: Not found: $src (skipped)" -ForegroundColor Yellow
    }
}

# Copy driver manifest (actual driver packs must be downloaded separately)
$manifestSrc = Join-Path $repoRoot 'drivers\manifest.json'
$manifestDst = "$DeployRoot\drivers\manifest.json"
if (Test-Path $manifestSrc) {
    Copy-Item $manifestSrc $manifestDst -Force
    Write-Host '  Copied: drivers\manifest.json' -ForegroundColor Green
} else {
    Write-Host '  WARN: drivers\manifest.json not found in repo (skipped)' -ForegroundColor Yellow
}

# ─── Firewall: open SMB for PXE clients on the local subnet ────────────────────
Write-Host ''
Write-Host '==> Verifying Windows Firewall allows SMB inbound' -ForegroundColor Cyan
$fwRule = Get-NetFirewallRule -Name 'FPS-SMB-In-TCP' -ErrorAction SilentlyContinue
if ($fwRule -and $fwRule.Enabled -eq 'True') {
    Write-Host '  SMB inbound rule is enabled.' -ForegroundColor Green
} else {
    # Enable the built-in File and Printer Sharing (SMB) rule
    Enable-NetFirewallRule -Name 'FPS-SMB-In-TCP' -ErrorAction SilentlyContinue
    Write-Host '  Enabled SMB inbound firewall rule.' -ForegroundColor Green
}

# ─── Done ──────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Deploy Share Setup Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
Write-Host "  1. Copy OS images to $DeployRoot\images\:"
Write-Host '       Mount Windows ISO, then run:'
Write-Host '         dism /Get-WimInfo /WimFile:D:\sources\install.wim'
Write-Host '         copy D:\sources\install.wim C:\deploy\images\win11.wim'
Write-Host ''
Write-Host '  2. After imaging a PC, scripts 03-07 will be run from:'
Write-Host "       \\$(hostname)\$ShareName\scripts\"
Write-Host ''
Write-Host '  3. When you update scripts in the repo, re-run this script'
Write-Host '     (or manually copy the changed files) to refresh the share.'
