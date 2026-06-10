# 04-install-packages.ps1
# Installs required software on a freshly imaged PC.
# Sources: winget (preferred), MSI/EXE packages from a share on pc-deploy.
#
# ADD YOUR PACKAGES to the $WingetPackages and $MsiPackages lists below.
# Secrets (license keys, tokens) must come from 1Password via 'op read'.
#
# USAGE: .\04-install-packages.ps1
#        .\04-install-packages.ps1 -PackageShare \\pc-deploy\deploy$ -DryRun

param(
    # UNC share on pc-deploy where MSI/EXE installers live
    [string]$PackageShare = '\\pc-deploy\deploy$\packages',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# WINGET PACKAGES - add/remove as needed
# Find IDs with: winget search <name>
# ---------------------------------------------------------------------------
$WingetPackages = @(
    # Browsers
    'Google.Chrome',
    'Mozilla.Firefox',

    # Remote & productivity
    'Microsoft.RemoteDesktopClient',
    '7zip.7zip',
    'Notepad++.Notepad++',

    # Dev tools (remove if not needed on all machines)
    # 'Git.Git',
    # 'Microsoft.VisualStudioCode',
)

# ---------------------------------------------------------------------------
# MSI / EXE packages from the package share
# Each entry: @{ Name='Display name'; File='relative\path.msi'; Args='/quiet' }
# ---------------------------------------------------------------------------
$MsiPackages = @(
    # Example:
    # @{ Name='Acrobat Reader'; File='acrobat\AcroRdrDC.msi'; Args='/quiet /norestart' },
)

# ---------------------------------------------------------------------------

function Install-Winget-Package([string]$Id) {
    Write-Host "  winget : $Id" -ForegroundColor Cyan
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process winget -ArgumentList "install --id $Id --silent --accept-package-agreements --accept-source-agreements" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $out = Get-Content $o -Raw; $err = Get-Content $e -Raw
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Host "    WARN: winget exit $($p.ExitCode) for $Id" -ForegroundColor Yellow
        if ($err) { Write-Host "    $err" -ForegroundColor DarkGray }
    } else {
        Write-Host "    OK (exit $($p.ExitCode))" -ForegroundColor Green
    }
}

function Install-Msi-Package([hashtable]$Pkg) {
    $path = Join-Path $PackageShare $Pkg.File
    Write-Host "  msi    : $($Pkg.Name) ($path)" -ForegroundColor Cyan
    if (-not (Test-Path $path)) { Write-Host "    SKIP: file not found" -ForegroundColor Yellow; return }
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process msiexec -ArgumentList "/i `"$path`" $($Pkg.Args)" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Host "    WARN: msiexec exit $($p.ExitCode)" -ForegroundColor Yellow
    } else {
        Write-Host "    OK" -ForegroundColor Green
    }
}

# --- Upgrade winget source first ---------------------------------------------
Write-Host '==> Refreshing winget sources...' -ForegroundColor Cyan
if (-not $DryRun) { winget source update | Out-Null }

# --- Winget packages ---------------------------------------------------------
Write-Host ''
Write-Host "==> Installing $($WingetPackages.Count) winget package(s)..." -ForegroundColor Cyan
foreach ($pkg in $WingetPackages) { Install-Winget-Package $pkg }

# --- MSI/EXE packages --------------------------------------------------------
if ($MsiPackages.Count -gt 0) {
    Write-Host ''
    Write-Host "==> Installing $($MsiPackages.Count) MSI package(s) from $PackageShare..." -ForegroundColor Cyan
    foreach ($pkg in $MsiPackages) { Install-Msi-Package $pkg }
}

Write-Host ''
Write-Host '==> Package installation complete.' -ForegroundColor Green
if ($DryRun) { Write-Host '    (Dry run - nothing was actually installed.)' -ForegroundColor Yellow }
