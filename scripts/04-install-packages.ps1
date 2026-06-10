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

# --- Set JuniperAdmin password from 1Password --------------------------------
# The unattend.xml creates the JuniperAdmin account with a placeholder password.
# This block replaces it with the real credential stored in 1Password before
# anything else runs. Requires 1Password CLI (op) to be authenticated.
#
# 1Password item: "junadmin" (local Windows admin for imaged PCs)
# Field: password
# To update the password in 1Password: op item edit junadmin --vault=<vault>
Write-Host '==> Setting JuniperAdmin password from 1Password...' -ForegroundColor Cyan
if (-not $DryRun) {
    try {
        $opExe = 'C:\Program Files\1Password CLI\op.exe'
        if (-not (Test-Path $opExe)) { $opExe = 'op' }   # fall back to PATH

        # Use op read with the vault-qualified path so no --reveal flag is needed
        # op:// URI format: op://<vault>/<item>/<field>
        # Item "pc-deploy" in vault "Private", username field = junadmin
        $junadminPass = & $opExe read 'op://Private/pc-deploy/password' 2>$null
        if (-not $junadminPass) { throw 'op read returned empty — is the CLI authenticated?' }

        $secPass = ConvertTo-SecureString $junadminPass -AsPlainText -Force
        Set-LocalUser -Name 'JuniperAdmin' -Password $secPass
        $junadminPass = $null   # clear from memory
        Write-Host '    JuniperAdmin password set.' -ForegroundColor Green
    } catch {
        Write-Host "    WARN: Could not set JuniperAdmin password: $_" -ForegroundColor Yellow
        Write-Host '    Run manually: op read "op://Juniper Design/junadmin/password" | ...'
        Write-Host '    Make sure op CLI is installed and authenticated (op signin).'
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

# --- Inventory agent -----------------------------------------------------------
# Registers this machine with the Juniper inventory system (FastAPI + Postgres
# on ENG-1 at 192.168.13.94:8080). Runs after all packages so the agent
# captures the fully-configured machine state.
Write-Host ''
Write-Host '==> Registering with Juniper inventory system...' -ForegroundColor Cyan
if (-not $DryRun) {
    try {
        Invoke-Expression (Invoke-RestMethod 'http://192.168.13.94:8080/static/install_agent.ps1')
        Write-Host '    Inventory agent installed.' -ForegroundColor Green
    } catch {
        Write-Host "    WARN: Inventory registration failed: $_" -ForegroundColor Yellow
        Write-Host '    The machine is still usable. Retry manually:'
        Write-Host '      irm http://192.168.13.94:8080/static/install_agent.ps1 | iex'
    }
}

Write-Host ''
Write-Host '==> Package installation complete.' -ForegroundColor Green
if ($DryRun) { Write-Host '    (Dry run - nothing was actually installed.)' -ForegroundColor Yellow }
