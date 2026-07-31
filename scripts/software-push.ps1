# software-push.ps1
# Post-imaging software installer for machines where the SYSTEM-context
# install-packages phase SKIPPED winget apps (winget cannot run as SYSTEM).
# RUN THIS AS A REAL USER (junadmin) via a scheduled task - NOT as SYSTEM.
#
# Installs: the standard winget app set (machine scope where supported), then
# the Microsoft 365 and Mastercam 2026 deployables from the inventory server.
# Best-effort per item; a single failure never aborts the rest. No secrets in
# this script - deployables fetch their own share creds from the LAN-only API.

param(
    [string]$ApiBase = 'http://192.168.5.141:8080',
    [switch]$SkipMastercam,
    [switch]$SkipOffice
)

$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\JuniperSetup\logs\software-push.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function L($m){ $s="{0}  {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; $s|Out-File $log -Append -Encoding utf8; Write-Host $s }

L '=== software push start ==='
L "context user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# --- resolve winget (lives under the user's WindowsApps) ---------------------
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) {
    $winget = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" -ErrorAction SilentlyContinue |
               Select-Object -First 1).FullName
}
if (-not $winget) {
    $p = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { $winget = Join-Path $p.InstallLocation 'winget.exe' }
}
L "winget: $(if($winget){$winget}else{'NOT FOUND - winget installs will be skipped'})"

$WingetPackages = @(
    'Microsoft.VCRedist.2015+.x64','Microsoft.VCRedist.2015+.x86',
    'Google.Chrome','Mozilla.Firefox',
    'Microsoft.RemoteDesktopClient',
    'Git.Git','OpenJS.NodeJS.LTS','Python.Python.3.12','Microsoft.PowerShell',
    'Microsoft.WSL','Ollama.Ollama','Anthropic.Claude'
)

if ($winget) {
    try { & $winget source update --disable-interactivity 2>&1 | Out-Null } catch {}
    foreach ($id in $WingetPackages) {
        L "  winget install $id ..."
        try {
            $a = @('install','--id',$id,'--exact','--silent','--accept-package-agreements',
                   '--accept-source-agreements','--disable-interactivity')
            # machine scope where the package supports it; winget ignores it otherwise
            $p = Start-Process $winget -ArgumentList ($a + @('--scope','machine')) -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -notin 0,-1978335189) {   # -1978335189 = already installed
                # retry without machine scope (some packages are user-only)
                $p = Start-Process $winget -ArgumentList $a -Wait -PassThru -NoNewWindow
            }
            L "    exit $($p.ExitCode)"
        } catch { L "    ERROR: $($_.Exception.Message)" }
    }
}

# --- deployables (they self-fetch share creds; long-running) -----------------
function Run-Deployable([string]$name,[string]$url){
    L "  deployable: $name  <- $url"
    try {
        $tmp = Join-Path $env:TEMP $name
        Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | ForEach-Object { L "    $_" }
        L "    $name exit: $LASTEXITCODE"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch { L "    ERROR running ${name}: $($_.Exception.Message)" }
}

if (-not $SkipOffice)    { Run-Deployable 'office365-install.ps1'    "$ApiBase/static/pkgs/office365-install.ps1" }
if (-not $SkipMastercam) { Run-Deployable 'mastercam2026-install.ps1' "$ApiBase/static/pkgs/mastercam2026-install.ps1" }

# --- re-register the inventory agent so the new software is reported ---------
L '  refreshing inventory agent registration...'
try { Invoke-RestMethod "$ApiBase/static/install_agent.ps1" -TimeoutSec 30 | Invoke-Expression } catch { L "    agent refresh error: $($_.Exception.Message)" }

L '=== software push done ==='
