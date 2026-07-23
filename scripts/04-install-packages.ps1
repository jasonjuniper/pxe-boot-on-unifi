# 04-install-packages.ps1
# Installs required software on a freshly imaged PC.
# Part of the Juniper automated imaging pipeline - runs via orchestrator.ps1.
#
# Exit codes (read by orchestrator.ps1):
#   0    - complete
#   3010 - reboot required (WSL feature enablement)
#
# PIPELINE ORDER:
#   Step 1: Pre-flight (MAC address + disk free % for catalog query)
#   Step 2: Inventory Agent MSI     (registers device, installs CA certs - must run first)
#   Step 3: Catalog packages        (queries /api/deploy/assignments, installs each, reports back)
#   Step 4: Winget + share MSI      (supplementary packages not managed by catalog)
#   Step 5: WSL2 + Ubuntu
#   Step 6: PowerShell 7 configuration
#   Step 7: npm global packages
#   Step 8: junadmin password + OEM activation
#
# CATALOG NOTE:
#   /api/deploy/assignments resolves packages by MAC address. The inventory server
#   handles skip logic (disk space, assignment rules) server-side, so this script
#   just downloads, verifies SHA256, and installs each non-skipped package.
#   Status (installed/up_to_date/skipped/failed) is reported back via
#   POST /api/deploy/status so the deploy dashboard stays current.
#
# WINGET + SYSTEM CONTEXT NOTE:
#   The orchestrator runs as SYSTEM. Winget does not work reliably in SYSTEM context.
#   Winget blocks are skipped when running as SYSTEM.
#   Catalog packages (MSI/EXE/script) work in SYSTEM context.
#
# CREDENTIAL NOTE:
#   junadmin password is set via the inventory server's /api/management/bootstrap
#   endpoint. No 1Password CLI or OP_SERVICE_ACCOUNT_TOKEN required.

param(
    [string]$PackageShare = '\\pc-deploy\deploy$\packages',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$invBase = 'http://192.168.5.141:8080'

. 'C:\ProgramData\JuniperSetup\Logging.ps1'
Initialize-ImagingLogging -PhaseName 'install-packages'
Write-PhaseHeader -Description 'Install Packages'

# ---- Append-only event timeline (best-effort) -------------------------------
# progress.ps1 provides Publish-Event; load it with safe no-op fallbacks so the
# timeline calls can never break this phase.
try { . 'C:\ProgramData\JuniperSetup\progress.ps1' } catch {}
if (-not (Get-Command Publish-Event -ErrorAction SilentlyContinue)) {
    function Publish-Event { param([Parameter(ValueFromRemainingArguments)]$args) }
}
if (-not (Get-Command Invoke-Step -ErrorAction SilentlyContinue)) {
    function Invoke-Step { param([string]$PhaseKey,[string]$Step,[scriptblock]$Script,[int]$Percent=-1,[switch]$Critical)
        try { & $Script; return $true } catch { if ($Critical) { throw }; return $false } }
}

# Detect SYSTEM context (winget/interactive tools will not work)
$runningAsSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match 'SYSTEM')
if ($runningAsSystem) {
    Write-Log 'Running as SYSTEM - winget-based installs will be skipped' -Level WARN
}

# ---------------------------------------------------------------------------
# WINGET PACKAGES (non-SYSTEM, supplementary to catalog)
# Packages already in the inventory catalog (7-Zip, Notepad++, PuTTY, WinGet)
# are excluded here to avoid double-installs.
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
    # Dev / AI toolchain
    'Git.Git',
    'OpenJS.NodeJS.LTS',
    'Python.Python.3.12',
    'Microsoft.PowerShell',
    # WSL2 kernel
    'Microsoft.WSL',
    # Local LLM + Claude Desktop
    'Ollama.Ollama',
    'Anthropic.Claude'
)

# ---------------------------------------------------------------------------
# MSI / EXE packages from the package share (manual overrides, SYSTEM-safe)
# These are separate from the inventory catalog and share-based MSIs.
# ---------------------------------------------------------------------------
$MsiPackages = @(
    # @{ Name='Example'; File='example\setup.msi'; Args='/quiet /norestart' },
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# Test-PackageInstalled: check detect_exe_path, detect_version_file, detect_reg_key
# detect_reg_key format: "HKXX:\path\to\key|ValueName"
#                     or "HKXX:\path\*|DisplayNameToMatch" (wildcard subkey search)
function Test-PackageInstalled {
    param([object]$Pkg)

    if ($Pkg.detect_exe_path) {
        if (Test-Path $Pkg.detect_exe_path) { return $true }
    }

    if ($Pkg.detect_version_file) {
        if (Test-Path $Pkg.detect_version_file) { return $true }
    }

    if ($Pkg.detect_reg_key) {
        $parts = $Pkg.detect_reg_key -split '\|', 2
        if ($parts.Count -eq 2) {
            $regPath = $parts[0]
            $regVal  = $parts[1]
            if ($regPath -match '\\\*') {
                # Wildcard: search all subkeys for DisplayName match
                # Strip the trailing \* segment to get the parent key
                $parent = $regPath -replace '\\[^\\]*\*[^\\]*$', ''
                foreach ($searchBase in @($parent, ($parent -replace 'SOFTWARE\\', 'SOFTWARE\WOW6432Node\'))) {
                    try {
                        $found = Get-ItemProperty "$searchBase\*" -ErrorAction SilentlyContinue |
                                 Where-Object { $_.DisplayName -eq $regVal }
                        if ($found) { return $true }
                    } catch {}
                }
            } else {
                # Direct: key must exist and have the named value
                try {
                    $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                    if ($props) {
                        $propNames = $props |
                            Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Name
                        if ($propNames -contains $regVal) { return $true }
                    }
                } catch {}
                # Also try WOW6432Node path
                $wow = $regPath -replace 'SOFTWARE\\', 'SOFTWARE\WOW6432Node\'
                if ($wow -ne $regPath) {
                    try {
                        $props2 = Get-ItemProperty -Path $wow -ErrorAction SilentlyContinue
                        if ($props2) {
                            $propNames2 = $props2 |
                                Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                                Select-Object -ExpandProperty Name
                            if ($propNames2 -contains $regVal) { return $true }
                        }
                    } catch {}
                }
            }
        }
    }
    return $false
}

# Report-PkgStatus: POST install outcome to /api/deploy/status (non-fatal if fails)
function Report-PkgStatus {
    param(
        [string]$Mac,
        [string]$Name,
        [string]$Status,
        [string]$Version      = '',
        [string]$SkipReason   = '',
        [string]$ErrorMessage = ''
    )
    if (-not $Mac) { return }
    try {
        $body = @{
            mac               = $Mac
            package_name      = $Name
            status            = $Status
            installed_version = $Version
            skip_reason       = $SkipReason
            error_message     = $ErrorMessage
        } | ConvertTo-Json
        Invoke-RestMethod "$invBase/api/deploy/status" -Method POST -Body $body `
            -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "    (status report failed: $_)" -Level WARN -PhaseOnly
    }
}

# Install-CatalogPackage: download, verify, install one catalog package
function Install-CatalogPackage {
    param(
        [int]$Index,
        [int]$Total,
        [object]$Pkg,
        [string]$Mac
    )

    $label = ('[{0:D2}/{1:D2}] {2}' -f $Index, $Total, $Pkg.name)

    # Server-side skip (low disk, assignment rule, etc.)
    if ($Pkg.skip) {
        Write-Log "$label  SKIP - $($Pkg.skip_reason)" -Level WARN
        Report-PkgStatus -Mac $Mac -Name $Pkg.name -Status 'skipped' -SkipReason $Pkg.skip_reason
        return
    }

    # Detection: already installed?
    $alreadyInstalled = Test-PackageInstalled -Pkg $Pkg
    if ($alreadyInstalled) {
        Write-Log "$label  already installed (v$($Pkg.version))"
        Report-PkgStatus -Mac $Mac -Name $Pkg.name -Status 'up_to_date' -Version $Pkg.version
        return
    }

    if ($DryRun) {
        Write-Log "$label  [dry run - would install v$($Pkg.version)]" -PhaseOnly
        return
    }

    # Download artifact
    $artifactFile = Split-Path ($Pkg.artifact_path -replace '/', '\') -Leaf
    $tempFile     = "$env:TEMP\$artifactFile"
    # Normalize path separators for URL
    $urlPath      = $Pkg.artifact_path -replace '\\', '/'
    $downloadUrl  = "$invBase/static/$urlPath"

    $sw  = [Diagnostics.Stopwatch]::StartNew()
    $o   = $null
    $e   = $null

    Write-Log "$label  downloading v$($Pkg.version)..." -PhaseOnly
    try {
        Invoke-WebRequest $downloadUrl -OutFile $tempFile -UseBasicParsing `
            -TimeoutSec 180 -ErrorAction Stop

        # SHA256 integrity check
        if ($Pkg.sha256) {
            $hash = (Get-FileHash $tempFile -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $Pkg.sha256.ToLower()) {
                throw "SHA256 mismatch: expected $($Pkg.sha256) got $hash"
            }
        }

        $installArgs = if ($Pkg.install_args) { $Pkg.install_args } else { '' }
        $o = [IO.Path]::GetTempFileName()
        $e = [IO.Path]::GetTempFileName()

        switch ($Pkg.package_type) {
            'msi' {
                # Add /qn if not already in install_args
                $quietFlag = if ($installArgs -notmatch '/q') { ' /qn' } else { '' }
                $allArgs   = "/i `"$tempFile`"$quietFlag"
                if ($installArgs) { $allArgs = "$allArgs $installArgs" }
                $p = Start-Process msiexec -ArgumentList $allArgs.Trim() `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $o -RedirectStandardError $e
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                    throw "msiexec exit $($p.ExitCode)"
                }
            }
            'exe' {
                $p = Start-Process $tempFile `
                        -ArgumentList $installArgs `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $o -RedirectStandardError $e
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                    throw "installer exit $($p.ExitCode)"
                }
            }
            'script' {
                $p = Start-Process 'powershell.exe' `
                        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tempFile`"" `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $o -RedirectStandardError $e
                if ($p.ExitCode -ne 0) { throw "script exit $($p.ExitCode)" }
            }
            default { throw "Unknown package_type: $($Pkg.package_type)" }
        }

        $sw.Stop()
        Write-Log ('{0}  OK ({1:F1}s)' -f $label, $sw.Elapsed.TotalSeconds)
        Report-PkgStatus -Mac $Mac -Name $Pkg.name -Status 'installed' -Version $Pkg.version

    } catch {
        $sw.Stop()
        Write-Log "$label  FAILED: $_" -Level ERROR
        Report-PkgStatus -Mac $Mac -Name $Pkg.name -Status 'failed' -ErrorMessage "$_"
    } finally {
        if ($o) { Remove-Item $o -ErrorAction SilentlyContinue }
        if ($e) { Remove-Item $e -ErrorAction SilentlyContinue }
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
}

function Install-WingetPackage {
    param([string]$Id)
    Write-Log "  winget: $Id" -PhaseOnly
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName()
    $e = [IO.Path]::GetTempFileName()
    $p = Start-Process winget `
            -ArgumentList @('install', '--id', $Id, '--silent',
                            '--accept-package-agreements', '--accept-source-agreements') `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e
    $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Log "    WARN: winget exit $($p.ExitCode) for $Id" -Level WARN
        if ($err) { Write-Log "    $($err.Trim())" -Level WARN -PhaseOnly }
    } else {
        Write-Log "    OK (exit $($p.ExitCode))" -PhaseOnly
    }
}

function Install-MsiPackage {
    param([hashtable]$Pkg)
    $path = Join-Path $PackageShare $Pkg.File
    Write-Log "  msi: $($Pkg.Name) ($path)" -PhaseOnly
    if (-not (Test-Path $path)) { Write-Log "    SKIP: file not found at $path" -Level WARN; return }
    if ($DryRun) { return }
    $o = [IO.Path]::GetTempFileName()
    $e = [IO.Path]::GetTempFileName()
    $p = Start-Process msiexec `
            -ArgumentList @('/i', "`"$path`"", $Pkg.Args) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e
    Remove-Item $o,$e -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Log "    WARN: msiexec exit $($p.ExitCode) for $($Pkg.Name)" -Level WARN
    } else {
        Write-Log "    OK" -PhaseOnly
    }
}

# ===========================================================================
# STEP 1 - Pre-flight: MAC address + disk free % for catalog query
# ===========================================================================
Write-Log '--- Step 1/8: Pre-flight ---'

$primaryMac = ''
try {
    # Prefer NIC with a default gateway (the imaging NIC)
    $nic = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
           Where-Object { $_.MACAddress -and $_.DefaultIPGateway } |
           Select-Object -First 1
    if (-not $nic) {
        $nic = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
               Select-Object -First 1
    }
    if ($nic) { $primaryMac = $nic.MACAddress.ToLower().Replace('-', ':') }
} catch {
    Write-Log "  Could not determine primary NIC MAC: $_" -Level WARN
}

$diskFreePct = 100.0
try {
    $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($disk.Size -gt 0) {
        $diskFreePct = [math]::Round($disk.FreeSpace * 100.0 / $disk.Size, 1)
    }
} catch {}

Write-Log "  MAC: $primaryMac   Disk free: ${diskFreePct}%"

# ===========================================================================
# STEP 2 - Inventory Agent MSI
# Must run first: registers the device fully so the catalog query resolves by MAC.
# Also installs the Juniper root CA cert (needed for any internal HTTPS).
# ===========================================================================
Write-Log '--- Step 2/8: Inventory Agent MSI ---'
Publish-Event -PhaseKey 'install-packages' -Step 'inventory-agent' -Status 'running' -Message 'Installing inventory agent MSI (registers device, installs CA cert)'

$msiOk = $false
if (-not $DryRun) {
    try {
        $msiTemp = "$env:TEMP\JuniperInventoryAgent.msi"
        $sw2     = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest "$invBase/static/JuniperInventoryAgent.msi" `
            -OutFile $msiTemp -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $p = Start-Process msiexec -ArgumentList "/i `"$msiTemp`" /qn" `
                -Wait -PassThru -ErrorAction Stop
        Remove-Item $msiTemp -Force -ErrorAction SilentlyContinue
        $sw2.Stop()
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Log ('Inventory Agent MSI installed (exit={0}, {1:F1}s)' -f $p.ExitCode, $sw2.Elapsed.TotalSeconds)
            $msiOk = $true
            Publish-Event -PhaseKey 'install-packages' -Step 'inventory-agent' -Status 'ok' -Message "Inventory agent MSI installed (exit=$($p.ExitCode))"
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
            Write-Log 'Inventory agent registration complete (one-liner mode)'
            Publish-Event -PhaseKey 'install-packages' -Step 'inventory-agent' -Status 'ok' -Message 'Inventory agent registered (one-liner fallback)'
        } catch {
            Write-Log "WARN: Inventory registration failed: $_" -Level WARN
            Write-Log "Retry manually: irm $invBase/static/install_agent.ps1 | iex" -Level WARN -PhaseOnly
            Publish-Event -PhaseKey 'install-packages' -Step 'inventory-agent' -Status 'error' -Message "Inventory agent registration failed: $_"
        }
    }
} else {
    Write-Log '  [dry run - would install Inventory Agent MSI]'
}

# ===========================================================================
# STEP 3 - Inventory catalog packages
# Query /api/deploy/assignments?mac=X&disk_free_pct=X
# Server returns all enabled packages with skip logic pre-computed.
# ===========================================================================
Write-Log '--- Step 3/8: Inventory catalog packages ---'
Publish-Event -PhaseKey 'install-packages' -Step 'catalog-install' -Status 'running' -Message 'Querying + installing inventory catalog packages'

$catalogPackages = @()
$catalogQueried  = $false

if ($primaryMac) {
    try {
        $macEnc = [uri]::EscapeDataString($primaryMac)
        $catalogUrl = "$invBase/api/deploy/assignments?mac=$macEnc&disk_free_pct=$diskFreePct"
        # PS 5.1 fix: assign then wrap (@(Invoke-RestMethod) collapses a top-level JSON array to 1 elem)
        $catalogPackages = Invoke-RestMethod $catalogUrl -TimeoutSec 15 -ErrorAction Stop
        $catalogPackages = @($catalogPackages)
        $catalogQueried  = $true
        Write-Log "Inventory catalog: $($catalogPackages.Count) package(s) assigned to this machine"
    } catch {
        Write-Log "WARN: Catalog query failed: $_ - proceeding without catalog" -Level WARN
        Publish-Event -PhaseKey 'install-packages' -Step 'catalog-install' -Status 'warning' -Message "Catalog query failed: $_ - proceeding without catalog"
    }
} else {
    Write-Log 'WARN: No primary MAC found - cannot query catalog (proceeding with static lists)' -Level WARN
    Publish-Event -PhaseKey 'install-packages' -Step 'catalog-install' -Status 'warning' -Message 'No primary MAC found - cannot query catalog'
}

if ($catalogQueried -and $catalogPackages.Count -gt 0) {
    $preSkipped = @($catalogPackages | Where-Object { $_.skip })
    Write-Log ("  {0} to process ({1} pre-skipped by server)" -f $catalogPackages.Count, $preSkipped.Count)
    Write-Log ''

    for ($ci = 0; $ci -lt $catalogPackages.Count; $ci++) {
        Install-CatalogPackage -Index ($ci + 1) -Total $catalogPackages.Count `
                               -Pkg $catalogPackages[$ci] -Mac $primaryMac
    }

    Write-Log ''
    Write-Log '--- Catalog install complete ---'
    Publish-Event -PhaseKey 'install-packages' -Step 'catalog-install' -Status 'ok' -Message "Catalog install complete ($($catalogPackages.Count) package(s) processed)"

} elseif ($catalogQueried) {
    Write-Log '  No packages assigned to this device in catalog'
    Publish-Event -PhaseKey 'install-packages' -Step 'catalog-install' -Status 'ok' -Message 'No packages assigned to this device in catalog'
}

# ===========================================================================
# STEP 4 - Winget + share MSI packages (supplementary)
# Skipped in SYSTEM context; catalog already covers MSI-managed tools.
# ===========================================================================
Write-Log '--- Step 4/8: Supplementary packages (winget + share MSI) ---'
Publish-Event -PhaseKey 'install-packages' -Step 'supplementary' -Status 'running' -Message 'Installing supplementary packages (winget + share MSI)'

if ($runningAsSystem) {
    Write-Log "Skipping $($WingetPackages.Count) winget package(s) - SYSTEM context" -Level WARN
    Publish-Event -PhaseKey 'install-packages' -Step 'supplementary' -Status 'info' -Message "Skipping $($WingetPackages.Count) winget package(s) - SYSTEM context"
} else {
    Write-Log 'Refreshing winget sources...'
    if (-not $DryRun) {
        $o = [IO.Path]::GetTempFileName()
        Start-Process winget -ArgumentList 'source update' -NoNewWindow -Wait `
            -RedirectStandardOutput $o -ErrorAction SilentlyContinue
        Remove-Item $o -ErrorAction SilentlyContinue
    }
    Write-Log "Installing $($WingetPackages.Count) winget package(s)..."
    foreach ($pkg in $WingetPackages) { Install-WingetPackage $pkg }
}

if ($MsiPackages.Count -gt 0) {
    Write-Log "Installing $($MsiPackages.Count) share MSI package(s)..."
    foreach ($pkg in $MsiPackages) { Install-MsiPackage $pkg }
} else {
    Write-Log 'No share MSI packages configured - skipping'
}
Publish-Event -PhaseKey 'install-packages' -Step 'supplementary' -Status 'ok' -Message 'Supplementary packages processed'

# ===========================================================================
# STEP 5 - WSL2 + Ubuntu
# DISM feature enablement works in SYSTEM context.
# Ubuntu distro install via wsl.exe requires non-SYSTEM.
# ===========================================================================
Write-Log '--- Step 5/8: WSL2 + Ubuntu ---'
Publish-Event -PhaseKey 'install-packages' -Step 'wsl2' -Status 'running' -Message 'Enabling WSL2 + installing Ubuntu'
$wslReboot = $false

if (-not $DryRun) {
    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
    foreach ($feat in $features) {
        Write-Log "  Enabling feature: $feat" -PhaseOnly
        $o = [IO.Path]::GetTempFileName()
        $e = [IO.Path]::GetTempFileName()
        $p = Start-Process 'dism.exe' `
                -ArgumentList @('/online', '/enable-feature', "/featurename:$feat", '/all', '/norestart') `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $o -RedirectStandardError $e
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 3010)     { $wslReboot = $true; Write-Log "  $feat enabled (reboot pending)" -PhaseOnly }
        elseif ($p.ExitCode -eq 0)    { Write-Log "  $feat enabled" -PhaseOnly }
        else { Write-Log "  WARN: DISM exit $($p.ExitCode) for $feat" -Level WARN }
    }

    if (-not $runningAsSystem) {
        Start-Process wsl -ArgumentList '--set-default-version 2' `
            -NoNewWindow -Wait -ErrorAction SilentlyContinue
        $o = [IO.Path]::GetTempFileName()
        $e = [IO.Path]::GetTempFileName()
        $p = Start-Process wsl `
                -ArgumentList @('--install', '-d', 'Ubuntu', '--no-launch') `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $o -RedirectStandardError $e
        $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
        Remove-Item $o,$e -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Log 'Ubuntu installed (initializes on first wsl launch)'
        } else {
            Write-Log ("WARN: wsl install exit {0} {1}" -f $p.ExitCode, $(if ($err) { $err.Trim() })) -Level WARN
        }
    } else {
        Write-Log 'Skipping Ubuntu distro install - SYSTEM context (run: wsl --install -d Ubuntu)' -Level WARN
    }
}

# ===========================================================================
# STEP 6 - PowerShell 7 as default shell
# ===========================================================================
Publish-Event -PhaseKey 'install-packages' -Step 'wsl2' -Status 'ok' -Message 'WSL2 feature enablement processed'

Write-Log '--- Step 6/8: PowerShell 7 configuration ---'
Publish-Event -PhaseKey 'install-packages' -Step 'powershell7' -Status 'running' -Message 'Configuring PowerShell 7 as default shell'

if (-not $DryRun) {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (Test-Path $pwsh) {
        $syspath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $pwshDir = 'C:\Program Files\PowerShell\7'
        if ($syspath -notmatch [regex]::Escape($pwshDir)) {
            [System.Environment]::SetEnvironmentVariable('Path', "$syspath;$pwshDir", 'Machine')
            Write-Log '  Added PS7 to system PATH' -PhaseOnly
        }
        Set-ItemProperty `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice' `
            -Name ProgId -Value 'Microsoft.PowerShellScript.1' -ErrorAction SilentlyContinue
        $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        if (Test-Path $wtSettings) {
            try {
                $wt  = Get-Content $wtSettings -Raw | ConvertFrom-Json
                $ps7 = $wt.profiles.list |
                       Where-Object { $_.source -match 'PowerShell' -and $_.name -match '7|Preview' } |
                       Select-Object -First 1
                if ($ps7) {
                    $wt.defaultProfile = $ps7.guid
                    $wt | ConvertTo-Json -Depth 20 | Set-Content $wtSettings -Encoding UTF8
                    Write-Log '  Windows Terminal default set to PS7' -PhaseOnly
                }
            } catch {
                Write-Log "  WARN: Windows Terminal settings update failed: $_" -Level WARN -PhaseOnly
            }
        }
        Write-Log 'PowerShell 7 configured'
        Publish-Event -PhaseKey 'install-packages' -Step 'powershell7' -Status 'ok' -Message 'PowerShell 7 configured as default shell'
    } else {
        Write-Log 'WARN: pwsh.exe not found - PS7 may need a reboot before it appears on PATH' -Level WARN
        Publish-Event -PhaseKey 'install-packages' -Step 'powershell7' -Status 'warning' -Message 'pwsh.exe not found - PS7 may need a reboot before it appears on PATH'
    }
}

# ===========================================================================
# STEP 7 - npm global packages
# ===========================================================================
Write-Log '--- Step 7/8: npm global packages ---'
Publish-Event -PhaseKey 'install-packages' -Step 'npm-globals' -Status 'running' -Message 'Installing npm global packages'

$NpmGlobalPackages = @(
    '@anthropic-ai/claude-code',
    '@wonderwhy-er/desktop-commander'
)

if ($runningAsSystem) {
    Write-Log "Skipping $($NpmGlobalPackages.Count) npm global packages - SYSTEM context" -Level WARN
    Publish-Event -PhaseKey 'install-packages' -Step 'npm-globals' -Status 'info' -Message "Skipping $($NpmGlobalPackages.Count) npm global package(s) - SYSTEM context"
} elseif (-not $DryRun) {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    $npm    = if ($npmCmd) { $npmCmd.Source } else { $null }
    if (-not $npm) { $npm = 'C:\Program Files\nodejs\npm.cmd' }
    if (Test-Path $npm) {
        foreach ($pkg in $NpmGlobalPackages) {
            Write-Log "  npm -g: $pkg" -PhaseOnly
            $o = [IO.Path]::GetTempFileName()
            $e = [IO.Path]::GetTempFileName()
            $p = Start-Process $npm -ArgumentList @('install', '-g', $pkg) `
                    -NoNewWindow -Wait -PassThru `
                    -RedirectStandardOutput $o -RedirectStandardError $e
            $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
            Remove-Item $o,$e -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0) {
                Write-Log "  WARN: npm exit $($p.ExitCode) for $pkg" -Level WARN
                if ($err) { Write-Log "  $($err.Trim())" -Level WARN -PhaseOnly }
            } else {
                Write-Log "  OK" -PhaseOnly
            }
        }
        Publish-Event -PhaseKey 'install-packages' -Step 'npm-globals' -Status 'ok' -Message "npm global packages processed ($($NpmGlobalPackages.Count) requested)"
    } else {
        Write-Log 'WARN: npm not found - Node.js may need a reboot to appear on PATH' -Level WARN
        Publish-Event -PhaseKey 'install-packages' -Step 'npm-globals' -Status 'warning' -Message 'npm not found - Node.js may need a reboot to appear on PATH'
    }
}

# ===========================================================================
# STEP 8 - junadmin password + OEM Windows activation
# ===========================================================================
Write-Log '--- Step 8/8: junadmin password + OEM activation ---'

# junadmin password via inventory bootstrap API (no 1Password needed)
Write-Log 'Setting junadmin password from inventory bootstrap API...'
Publish-Event -PhaseKey 'install-packages' -Step 'set-junadmin-password' -Status 'running' -Message 'Setting junadmin password from inventory bootstrap API'
if (-not $DryRun) {
    try {
        $resp = Invoke-RestMethod "$invBase/api/management/bootstrap" -TimeoutSec 10 -ErrorAction Stop
        $bPass = $resp.password
        if (-not $bPass) { throw 'Bootstrap API returned empty password' }
        $secPass = ConvertTo-SecureString $bPass -AsPlainText -Force
        Set-LocalUser -Name 'junadmin' -Password $secPass
        $secPass = $null; $bPass = $null; $resp = $null
        Write-Log 'junadmin password updated successfully'
        Publish-Event -PhaseKey 'install-packages' -Step 'set-junadmin-password' -Status 'ok' -Message 'junadmin password updated successfully'
    } catch {
        Write-Log "Could not set junadmin password via bootstrap API: $_" -Level ERROR
        Write-Log 'Machine will remain with CHANGEME password - log in manually and re-run' -Level ERROR
        Publish-Event -PhaseKey 'install-packages' -Step 'set-junadmin-password' -Status 'error' -Message "Could not set junadmin password via bootstrap API: $_"
    }
}

# OEM UEFI key activation (reads embedded key from ACPI MSDM table)
# Machines that shipped with Home and were imaged with Pro will have an edition
# mismatch - the Home key cannot be applied to a Pro install.  In that case we
# skip activation here and let Windows auto-activate via digital license.
Write-Log 'Activating Windows via OEM UEFI key...'
Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'running' -Message 'Activating Windows via OEM UEFI key'
if (-not $DryRun) {
    try {
        $sl = Get-WmiObject -Query `
            'SELECT OA3xOriginalProductKey, OA3xOriginalProductKeyDescription FROM SoftwareLicensingService' `
            -ErrorAction Stop
        $oemKey  = $sl.OA3xOriginalProductKey
        $oemDesc = $sl.OA3xOriginalProductKeyDescription

        if (-not $oemKey -or $oemKey.Length -eq 0) {
            Write-Log 'No OEM UEFI key found - trying inventory-assigned license key (whitebox / OEM:DM)'
            # Whitebox / self-built PCs have no firmware MSDM key, so the block above
            # finds nothing. If an admin has ARMED a one-time release
            # (POST /admin/licenses/arm/{assignment_id}) the inventory server will hand
            # this machine the key assigned to it. Matched by MAC first (the SMBIOS
            # serial is a placeholder on these boards) with serial as a fallback. The
            # key is one-shot and never logged - only slmgr's result text is written.
            $assignedKey = $null
            try {
                $nic = Get-CimInstance Win32_NetworkAdapter |
                    Where-Object { $_.PhysicalAdapter -and $_.MACAddress -and $_.Name -notmatch 'wi.?fi|wireless|802\.11' } |
                    Select-Object -First 1
                $macQ = if ($nic) { $nic.MACAddress.ToLower() } else { '' }
                $serQ = "$((Get-CimInstance Win32_BIOS).SerialNumber)"
                $luri = "$invBase/ingest/license-key?package=Windows" +
                        "&mac=$([uri]::EscapeDataString($macQ))" +
                        "&serial=$([uri]::EscapeDataString($serQ))"
                $lres = Invoke-RestMethod $luri -TimeoutSec 15 -ErrorAction Stop
                $assignedKey = $lres.license_key
            } catch {
                Write-Log "No inventory-assigned key collected (not armed / none assigned / unreachable) - digital license or KMS will activate: $_"
                Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'info' -Message 'No inventory-assigned key (not armed / none) - digital license/KMS will activate'
            }
            if ($assignedKey) {
                $ipkText = (cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $assignedKey 2>&1) -join ' '
                $assignedKey = $null
                Write-Log "Assigned-key install: $ipkText"
                if ($ipkText -match '0xC004') {
                    Write-Log 'Inventory-assigned key rejected by activation server - may need a different key or manual activation' -Level WARN
                    Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'warning' -Message 'Inventory-assigned key rejected by activation server'
                } else {
                    $ato = (cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1) -join ' '
                    Write-Log "Activation (inventory key): $ato"
                    Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'ok' -Message 'Windows activated via inventory-assigned key'
                }
            }
        } else {
            # Detect edition mismatch before touching slmgr.
            # OA3xOriginalProductKeyDescription contains the key's intended edition.
            $osCaption  = (Get-WmiObject Win32_OperatingSystem).Caption
            $keyIsHome  = $oemDesc -match '\bHome\b'
            $keyIsPro   = $oemDesc -match '\bPro\b'
            $osIsPro    = $osCaption -match '\bPro\b'
            $osIsHome   = $osCaption -match '\bHome\b'
            $mismatch   = ($keyIsHome -and $osIsPro) -or ($keyIsPro -and $osIsHome)

            if ($mismatch) {
                $keyEdition = if ($keyIsHome) { 'Home' } elseif ($keyIsPro) { 'Pro' } else { 'unknown' }
                Write-Log "OEM key is for Windows $keyEdition but machine is imaged with a different edition - skipping OEM key, Windows will activate via digital license" -Level WARN
                Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'warning' -Message "OEM key edition mismatch (key=$keyEdition) - using digital license"
            } else {
                # Key value is never logged - only slmgr result text appears
                $ipkText = (cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $oemKey 2>&1) -join ' '
                Write-Log "Key install: $ipkText"

                if ($ipkText -match '0xC004F069') {
                    Write-Log 'Edition mismatch detected after key install - Windows will activate via digital license' -Level WARN
                    Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'warning' -Message 'Edition mismatch after key install - digital license'
                } elseif ($ipkText -match '0xC004') {
                    Write-Log 'OEM key rejected by activation server - Windows will activate via digital license or needs manual activation' -Level WARN
                    Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'warning' -Message 'OEM key rejected by activation server - digital license / manual'
                } else {
                    $ato = (cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1) -join ' '
                    Write-Log "Activation: $ato"
                    Publish-Event -PhaseKey 'install-packages' -Step 'oem-activation' -Status 'ok' -Message 'Windows activated via OEM key'
                }
            }
        }
    } catch {
        Write-Log "WARN: OEM key read failed: $_" -Level WARN
    }
}

# ===========================================================================
# Final summary
# ===========================================================================
$dryNote = if ($DryRun) { ' (dry run)' } else { '' }

if ($wslReboot) {
    Write-Log 'WSL feature enablement requires a reboot'
    Write-PhaseSummary -ExitCode 3010 -Notes "WSL reboot pending$dryNote" -Reboot
    exit 3010
}

Write-Log "Package installation complete$dryNote"
Write-PhaseSummary -ExitCode 0 -Notes "catalog=$($catalogPackages.Count), winget=$(if ($runningAsSystem) { 'skipped' } else { $WingetPackages.Count }), msi=$($MsiPackages.Count)$dryNote"
exit 0
