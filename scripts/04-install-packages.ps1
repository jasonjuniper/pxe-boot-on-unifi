# 04-install-packages.ps1
# Installs required software on a freshly imaged PC.
# Part of the Juniper automated imaging pipeline - runs via orchestrator.ps1.
#
# Exit codes (read by orchestrator.ps1):
#   0    - complete
#   3010 - reboot required (WSL feature enablement)
#   1    - fatal error
#
# WINGET + SYSTEM CONTEXT NOTE:
# The orchestrator runs as SYSTEM. Winget does not work reliably in SYSTEM context
# (requires a user profile). Winget blocks are skipped when running as SYSTEM and
# logged as WARN. Packages that must be installed should be added to $MsiPackages
# as direct MSI/EXE downloads, or installed interactively after first login.
# TODO: Replace winget with Chocolatey or direct MSI downloads for SYSTEM support.
#
# CREDENTIAL NOTE:
# JuniperAdmin password is set via the inventory server's /api/management/bootstrap
# endpoint. No 1Password CLI or OP_SERVICE_ACCOUNT_TOKEN required.
#
# USAGE: .\04-install-packages.ps1
#        .\04-install-packages.ps1 -PackageShare \\pc-deploy\deploy$ -DryRun

param(
    # UNC share on pc-deploy where MSI/EXE installers live
    [string]$PackageShare = '\\pc-deploy\deploy$\packages',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'install-packages'
Write-PhaseHeader -Description 'Install Packages'

# Detect SYSTEM context (winget/interactive tools will not work)
$runningAsSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match 'SYSTEM')
if ($runningAsSystem) {
    Write-Log 'Running as SYSTEM - winget-based installs will be skipped' -Level WARN
    Write-Log 'Winget packages must be installed interactively or via Chocolatey/MSI' -Level WARN
}

# ---------------------------------------------------------------------------
# WINGET PACKAGES - add/remove as needed
# Find IDs with: winget search <name>
# NOTE: These are SKIPPED when running as SYSTEM. See header note above.
# ---------------------------------------------------------------------------
$WingetPackages = @(
    # Runtime prerequisites
    'Microsoft.VCRedist.2015+.x64',
    'Microsoft.VCRedist.2015+.x86',

    # Browsers
    'Google.Chrome',
    'Mozilla.Firefox',

    # Remote & productivity
    'Microsoft.RemoteDesktopClient',
    '7zip.7zip',
    'Notepad++.Notepad++',
    'PuTTY.PuTTY',

    # Dev / AI toolchain
    'Git.Git',
    'OpenJS.NodeJS.LTS',
    'Python.Python.3.12',
    'Microsoft.PowerShell',

    # WSL2 kernel
    'Microsoft.WSL',

    # Local LLM
    'Ollama.Ollama',

    # Claude Desktop
    'Anthropic.Claude'
)

# ---------------------------------------------------------------------------
# MSI / EXE packages from the package share (work in SYSTEM context)
# Each entry: @{ Name='Display name'; File='relative\path.msi'; Args='/quiet' }
# ---------------------------------------------------------------------------
$MsiPackages = @(
    # Example:
    # @{ Name='Acrobat Reader'; File='acrobat\AcroRdrDC.msi'; Args='/quiet /norestart' },
)

# ---------------------------------------------------------------------------

function Install-Winget-Package([string]$Id) {
    Write-Log "  winget: $Id" -PhaseOnly
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process winget `
            -ArgumentList @('install', '--id', $Id, '--silent', '--accept-package-agreements', '--accept-source-agreements') `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Log "    WARN: winget exit $($p.ExitCode) for $Id" -Level WARN
        if ($err) { Write-Log "    $($err.Trim())" -Level WARN -PhaseOnly }
    } else {
        Write-Log "    OK (exit $($p.ExitCode))" -PhaseOnly
    }
}

function Install-Msi-Package([hashtable]$Pkg) {
    $path = Join-Path $PackageShare $Pkg.File
    Write-Log "  msi: $($Pkg.Name) ($path)" -PhaseOnly
    if (-not (Test-Path $path)) { Write-Log "    SKIP: file not found at $path" -Level WARN; return }
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process msiexec -ArgumentList @("/i", "`"$path`"", $Pkg.Args) `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Log "    WARN: msiexec exit $($p.ExitCode) for $($Pkg.Name)" -Level WARN
    } else {
        Write-Log "    OK" -PhaseOnly
    }
}

# --- Winget packages ----------------------------------------------------------
# Skipped when running as SYSTEM (no user profile / store access)
if ($runningAsSystem) {
    Write-Log "Skipping $($WingetPackages.Count) winget package(s) - SYSTEM context" -Level WARN
} else {
    Write-Log 'Refreshing winget sources...'
    if (-not $DryRun) {
        $o = [IO.Path]::GetTempFileName()
        Start-Process winget -ArgumentList 'source update' -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
        Remove-Item $o -ErrorAction SilentlyContinue
    }
    Write-Log "Installing $($WingetPackages.Count) winget package(s)..."
    foreach ($pkg in $WingetPackages) { Install-Winget-Package $pkg }
}

# --- MSI/EXE packages ---------------------------------------------------------
if ($MsiPackages.Count -gt 0) {
    Write-Log "Installing $($MsiPackages.Count) MSI package(s) from $PackageShare..."
    foreach ($pkg in $MsiPackages) { Install-Msi-Package $pkg }
} else {
    Write-Log 'No MSI packages configured - skipping'
}

# --- WSL2 + Ubuntu ------------------------------------------------------------
# DISM enables WSL features (works in SYSTEM context).
# Ubuntu distro install via wsl.exe may not work as SYSTEM - skip if so.
Write-Log 'Installing WSL2 + Ubuntu...'
$wslReboot = $false
if (-not $DryRun) {
    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
    foreach ($feat in $features) {
        Write-Log "  Enabling feature: $feat" -PhaseOnly
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        $p = Start-Process 'dism.exe' `
            -ArgumentList @("/online", "/enable-feature", "/featurename:$feat", "/all", "/norestart") `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 3010) { $wslReboot = $true; Write-Log "  Feature $feat enabled (reboot pending)" -PhaseOnly }
        elseif ($p.ExitCode -eq 0) { Write-Log "  Feature $feat enabled" -PhaseOnly }
        else { Write-Log "  WARN: DISM exit $($p.ExitCode) for $feat" -Level WARN }
    }

    if (-not $runningAsSystem) {
        # Set WSL default version to 2 and install Ubuntu
        Start-Process wsl -ArgumentList '--set-default-version 2' -NoNewWindow -Wait -ErrorAction SilentlyContinue
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        $p = Start-Process wsl -ArgumentList @('--install', '-d', 'Ubuntu', '--no-launch') `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Log 'Ubuntu installed (initializes on first wsl launch)'
        } else {
            Write-Log "WARN: wsl install exit $($p.ExitCode) $(if ($err) { $err.Trim() })" -Level WARN
        }
    } else {
        Write-Log 'Skipping Ubuntu distro install - SYSTEM context (run wsl --install -d Ubuntu manually after first login)' -Level WARN
    }
}

# --- PowerShell 7 as default shell --------------------------------------------
Write-Log 'Configuring PowerShell 7 as default shell...'
if (-not $DryRun) {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (Test-Path $pwsh) {
        # Ensure pwsh.exe is on system PATH
        $syspath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $pwshDir = 'C:\Program Files\PowerShell\7'
        if ($syspath -notmatch [regex]::Escape($pwshDir)) {
            [System.Environment]::SetEnvironmentVariable('Path', "$syspath;$pwshDir", 'Machine')
            Write-Log '  Added PS7 to system PATH' -PhaseOnly
        }
        # Register .ps1 association
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice' `
            -Name ProgId -Value 'Microsoft.PowerShellScript.1' -ErrorAction SilentlyContinue
        # Windows Terminal default profile
        $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        if (Test-Path $wtSettings) {
            try {
                $wt = Get-Content $wtSettings -Raw | ConvertFrom-Json
                $ps7 = $wt.profiles.list | Where-Object { $_.source -match 'PowerShell' -and $_.name -match '7|Preview' } | Select-Object -First 1
                if ($ps7) {
                    $wt.defaultProfile = $ps7.guid
                    $wt | ConvertTo-Json -Depth 20 | Set-Content $wtSettings -Encoding UTF8
                    Write-Log '  Windows Terminal default set to PS7' -PhaseOnly
                }
            } catch {
                Write-Log "  WARN: WT settings update failed: $_" -Level WARN -PhaseOnly
            }
        }
        Write-Log 'PowerShell 7 configured'
    } else {
        Write-Log 'WARN: pwsh.exe not found - PS7 may need a reboot before it appears' -Level WARN
    }
}

# --- npm global packages -------------------------------------------------------
Write-Log 'Installing npm global packages...'
$NpmGlobalPackages = @(
    '@anthropic-ai/claude-code',
    '@wonderwhy-er/desktop-commander'
)
if ($runningAsSystem) {
    Write-Log "Skipping $($NpmGlobalPackages.Count) npm global packages - SYSTEM context" -Level WARN
} elseif (-not $DryRun) {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    $npm = if ($npmCmd) { $npmCmd.Source } else { $null }
    if (-not $npm) { $npm = 'C:\Program Files\nodejs\npm.cmd' }
    if (Test-Path $npm) {
        foreach ($pkg in $NpmGlobalPackages) {
            Write-Log "  npm -g: $pkg" -PhaseOnly
            $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
            $p = Start-Process $npm -ArgumentList @('install', '-g', $pkg) `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
            $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
            Remove-Item $o,$e -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0) {
                Write-Log "  WARN: npm exit $($p.ExitCode) for $pkg" -Level WARN
                if ($err) { Write-Log "  $($err.Trim())" -Level WARN -PhaseOnly }
            } else {
                Write-Log "  OK" -PhaseOnly
            }
        }
    } else {
        Write-Log 'WARN: npm not found - Node.js may need a reboot to appear on PATH' -Level WARN
    }
}

# --- Set JuniperAdmin password via inventory bootstrap API --------------------
# Uses the inventory server's /api/management/bootstrap endpoint which reads
# from C:\inventory\junadmin.key on pc-deploy. Works under SYSTEM context
# (no op CLI or OP_SERVICE_ACCOUNT_TOKEN needed - just an HTTP call on the LAN).
Write-Log 'Setting JuniperAdmin password from inventory bootstrap API...'
if (-not $DryRun) {
    try {
        $bootstrapUrl = 'http://inventory.juniperdesign.local:8080/api/management/bootstrap'
        $resp = Invoke-RestMethod $bootstrapUrl -TimeoutSec 10 -ErrorAction Stop
        $junadminPass = $resp.password
        if (-not $junadminPass) { throw 'Bootstrap API returned empty password' }

        $secPass = ConvertTo-SecureString $junadminPass -AsPlainText -Force
        Set-LocalUser -Name 'JuniperAdmin' -Password $secPass
        $junadminPass = $null
        $resp = $null
        Write-Log 'JuniperAdmin password updated successfully'
    } catch {
        Write-Log "Could not set JuniperAdmin password via bootstrap API: $_" -Level ERROR
        Write-Log 'Machine will remain with CHANGEME password - log in manually and re-run' -Level ERROR
    }
}

# --- Windows OEM activation ---------------------------------------------------
Write-Log 'Activating Windows (UEFI OEM key)...'
if (-not $DryRun) {
    try {
        $oemKey = (Get-WmiObject -Query 'SELECT OA3xOriginalProductKey FROM SoftwareLicensingService' `
                      -ErrorAction Stop).OA3xOriginalProductKey
        if ($oemKey -and $oemKey.Length -gt 0) {
            # slmgr output is the result message - key value never appears in logs
            $ipk = cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $oemKey 2>&1
            Write-Log "Key installed: $($ipk -join ' ')"
            $ato = cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1
            Write-Log "Activation: $($ato -join ' ')"
        } else {
            Write-Log 'No OEM UEFI key found (VM or key not embedded) - digital license or KMS will activate'
        }
    } catch {
        Write-Log "WARN: OEM key read failed: $_" -Level WARN
    }
}

# --- Inventory agent + MSI install -------------------------------------------
# 1. Install the MSI (installs CA certs, registers scheduled task for ongoing
#    hardware monitoring, and appears in Add/Remove Programs).
#    The MSI also runs the inventory agent immediately via its scheduled task.
# 2. Fall back to the install_agent.ps1 one-liner if MSI install fails, so
#    the machine is at least registered in the inventory DB even without the
#    persistent scheduled task.
$invBase = 'http://192.168.5.141:8080'
Write-Log 'Installing Juniper Inventory Agent MSI...'
if (-not $DryRun) {
    $msiOk = $false
    try {
        $msiTemp = "$env:TEMP\JuniperInventoryAgent.msi"
        Invoke-WebRequest "$invBase/static/JuniperInventoryAgent.msi" `
            -OutFile $msiTemp -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $p = Start-Process msiexec -ArgumentList "/i `"$msiTemp`" /qn" -Wait -PassThru -ErrorAction Stop
        Remove-Item $msiTemp -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Log "Inventory Agent MSI installed (exit=$($p.ExitCode))"
            $msiOk = $true
        } else {
            Write-Log "WARN: MSI install exit $($p.ExitCode) - falling back to one-liner" -Level WARN
        }
    } catch {
        Write-Log "WARN: MSI install failed: $_ - falling back to one-liner" -Level WARN
    }

    if (-not $msiOk) {
        Write-Log 'Re-registering via install_agent.ps1 (MSI fallback)...'
        try {
            Invoke-Expression (Invoke-RestMethod "$invBase/static/install_agent.ps1" -TimeoutSec 15)
            Write-Log 'Inventory agent: registration complete (one-liner mode)'
        } catch {
            Write-Log "WARN: Inventory registration failed: $_" -Level WARN
            Write-Log "Retry manually: irm $invBase/static/install_agent.ps1 | iex" -Level WARN -PhaseOnly
        }
    }
}

# --- Final summary ------------------------------------------------------------
$dryNote = if ($DryRun) { ' (dry run)' } else { '' }
$exitCode = if ($wslReboot) { 3010 } else { 0 }

if ($wslReboot) {
    Write-Log 'WSL feature enablement requires a reboot'
    Write-PhaseSummary -ExitCode 3010 -Notes "WSL reboot pending$dryNote" -Reboot
    exit 3010
}

Write-Log "Package installation complete$dryNote"
Write-PhaseSummary -ExitCode 0 -Notes "winget=$(if ($runningAsSystem) {'skipped'} else {$WingetPackages.Count}), msi=$($MsiPackages.Count)$dryNote"
exit 0
