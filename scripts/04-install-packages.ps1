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
    # Runtime prerequisites — install before anything that links against them
    'Microsoft.VCRedist.2015+.x64',     # VC++ runtime (Python, Git internals, Ollama)
    'Microsoft.VCRedist.2015+.x86',     # 32-bit variant for legacy app compatibility

    # Browsers
    'Google.Chrome',
    'Mozilla.Firefox',

    # Remote & productivity
    'Microsoft.RemoteDesktopClient',
    '7zip.7zip',
    'Notepad++.Notepad++',

    # Dev / AI toolchain — required for Windows MCP, Desktop Commander, Claude Code
    'Git.Git',
    'OpenJS.NodeJS.LTS',      # npm, npx
    'Python.Python.3.12',
    'Microsoft.PowerShell',   # PowerShell 7

    # WSL2 kernel package — must be installed before the WSL2 section below runs
    # (handles the Linux kernel; DISM below handles the Windows optional features)
    'Microsoft.WSL',

    # Local LLM
    'Ollama.Ollama',

    # Claude Desktop (Windows MCP installs as a Claude plugin after this)
    'Anthropic.Claude',
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

# --- WSL2 + Ubuntu ------------------------------------------------------------
# Two-part setup:
#   1. winget Microsoft.WSL (above) installs the WSL2 Linux kernel package.
#   2. DISM below enables the Windows optional features (Subsystem-Linux +
#      VirtualMachinePlatform). A reboot is required after feature enablement;
#      the RunOnce chain in 03-windows-update.ps1 handles that reboot, so this
#      script just enables the features and schedules the Ubuntu install.
# Ubuntu finishes initializing on first interactive launch (wsl -d Ubuntu).
Write-Host ''
Write-Host '==> Installing WSL2 + Ubuntu...' -ForegroundColor Cyan
if (-not $DryRun) {
    # Enable required Windows features (silently, no reboot yet)
    $features = @(
        'Microsoft-Windows-Subsystem-Linux',
        'VirtualMachinePlatform'
    )
    foreach ($feat in $features) {
        Write-Host "  Enabling feature: $feat" -ForegroundColor Cyan
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        $p = Start-Process 'dism.exe' `
            -ArgumentList "/online /enable-feature /featurename:$feat /all /norestart" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $out = Get-Content $o -Raw -ErrorAction SilentlyContinue
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Host '    OK' -ForegroundColor Green
        } else {
            Write-Host "    WARN: DISM exit $($p.ExitCode) for $feat" -ForegroundColor Yellow
        }
    }

    # Set WSL default version to 2
    $o = [IO.Path]::GetTempFileName()
    Start-Process wsl -ArgumentList '--set-default-version 2' `
        -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
    Remove-Item $o -ErrorAction SilentlyContinue

    # Install Ubuntu distro (--no-launch so it doesn't open a console window)
    Write-Host '  Installing Ubuntu distro (no-launch)...' -ForegroundColor Cyan
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process wsl -ArgumentList '--install -d Ubuntu --no-launch' `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $out = Get-Content $o -Raw -ErrorAction SilentlyContinue
    $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
        Write-Host '    Ubuntu installed (will finish initializing on first launch).' -ForegroundColor Green
    } else {
        Write-Host "    WARN: wsl install exit $($p.ExitCode)" -ForegroundColor Yellow
        if ($err) { Write-Host "    $($err.Trim())" -ForegroundColor DarkGray }
    }
}

# --- Set PowerShell 7 as default shell ----------------------------------------
# Registers pwsh.exe as the default shell for new terminals, Explorer "Open
# PowerShell here", and the Windows Terminal default profile.
Write-Host ''
Write-Host '==> Setting PowerShell 7 as default shell...' -ForegroundColor Cyan
if (-not $DryRun) {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (Test-Path $pwsh) {
        # Set HKLM default shell (used by runas, Task Scheduler, etc.)
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
            -Name Shell -Value 'explorer.exe' -ErrorAction SilentlyContinue
        # Register pwsh as the OpenWithProgids default for .ps1 files
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice' `
            -Name ProgId -Value 'Microsoft.PowerShellScript.1' -ErrorAction SilentlyContinue
        # Windows Terminal: set PS7 as default profile (if WT is present)
        $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        if (Test-Path $wtSettings) {
            $wt = Get-Content $wtSettings -Raw | ConvertFrom-Json
            $ps7profile = $wt.profiles.list | Where-Object { $_.source -match 'PowerShell' -and $_.name -match '7|Preview' } | Select-Object -First 1
            if ($ps7profile) {
                $wt.defaultProfile = $ps7profile.guid
                $wt | ConvertTo-Json -Depth 20 | Set-Content $wtSettings -Encoding UTF8
                Write-Host '    Windows Terminal default profile set to PS7.' -ForegroundColor Green
            }
        }
        # Ensure pwsh.exe is on the system PATH
        $syspath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
        $pwshDir = 'C:\Program Files\PowerShell\7'
        if ($syspath -notmatch [regex]::Escape($pwshDir)) {
            [System.Environment]::SetEnvironmentVariable('Path', "$syspath;$pwshDir", 'Machine')
            Write-Host '    Added PS7 to system PATH.' -ForegroundColor Green
        }
        Write-Host '    PowerShell 7 default shell configured.' -ForegroundColor Green
    } else {
        Write-Host '    WARN: pwsh.exe not found — was PowerShell 7 installed?' -ForegroundColor Yellow
    }
}

# --- npm global packages (Windows MCP, Desktop Commander, Claude Code) --------
# Requires Node.js to be installed (winget OpenJS.NodeJS.LTS above).
# Claude Code is the Anthropic CLI; Windows MCP and Desktop Commander are
# MCP servers that Claude Code/Cowork uses to control this machine.
Write-Host ''
Write-Host '==> Installing npm global packages...' -ForegroundColor Cyan

$NpmGlobalPackages = @(
    '@anthropic-ai/claude-code',         # Claude Code CLI
    '@wonderwhy-er/desktop-commander',   # Desktop Commander MCP (npm-based)
    # NOTE: Windows MCP is a Claude plugin — install it from Claude Desktop's
    #       Settings > Extensions after first login, not via npm.
)

if (-not $DryRun) {
    # Refresh PATH so npm is available after Node.js was just installed
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')

    $npm = (Get-Command npm -ErrorAction SilentlyContinue)?.Source
    if (-not $npm) { $npm = 'C:\Program Files\nodejs\npm.cmd' }

    if (Test-Path $npm) {
        foreach ($pkg in $NpmGlobalPackages) {
            Write-Host "  npm -g : $pkg" -ForegroundColor Cyan
            $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
            $p = Start-Process $npm -ArgumentList "install -g $pkg" `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
            $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
            Remove-Item $o,$e -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0) {
                Write-Host "    WARN: npm exit $($p.ExitCode) for $pkg" -ForegroundColor Yellow
                if ($err) { Write-Host "    $($err.Trim())" -ForegroundColor DarkGray }
            } else {
                Write-Host '    OK' -ForegroundColor Green
            }
        }
    } else {
        Write-Host '    WARN: npm not found — Node.js may need a reboot to appear on PATH.' -ForegroundColor Yellow
        Write-Host '    Re-run this script after reboot to install npm packages.'
    }
}

# --- Inventory agent -----------------------------------------------------------
# Registers this machine with the Juniper inventory system (FastAPI + Postgres
# on ENG-1 at 192.168.5.141:8080). Runs after all packages so the agent
# captures the fully-configured machine state.
Write-Host ''
Write-Host '==> Registering with Juniper inventory system...' -ForegroundColor Cyan
if (-not $DryRun) {
    try {
        Invoke-Expression (Invoke-RestMethod 'http://192.168.5.141:8080/static/install_agent.ps1')
        Write-Host '    Inventory agent installed.' -ForegroundColor Green
    } catch {
        Write-Host "    WARN: Inventory registration failed: $_" -ForegroundColor Yellow
        Write-Host '    The machine is still usable. Retry manually:'
        Write-Host '      irm http://192.168.5.141:8080/static/install_agent.ps1 | iex'
    }
}

Write-Host ''
Write-Host '==> Package installation complete.' -ForegroundColor Green
if ($DryRun) { Write-Host '    (Dry run - nothing was actually installed.)' -ForegroundColor Yellow }
