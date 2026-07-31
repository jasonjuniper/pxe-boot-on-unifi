# software-push-all.ps1
# SELF-DRIVING post-imaging software installer for a machine that is only
# intermittently online (laptop Wi-Fi sleeps). Registered as a scheduled task
# that runs AS junadmin (winget needs a real user), at logon AND every 15 min.
# Each run installs only what is still missing, then when everything is present
# it removes its own repeating trigger so it stops.
#
# Order: 12 winget apps (launched CONCURRENTLY) -> Microsoft 365 -> Mastercam 2026.
# No secrets here - the Office/Mastercam deployables fetch their own share creds
# from the LAN-only inventory API.

param(
    [string]$ApiBase  = 'http://192.168.5.141:8080',
    [string]$TaskName = 'JuniperSoftwarePush'
)
$ErrorActionPreference = 'Continue'
$root = 'C:\ProgramData\JuniperSetup'
$logd = "$root\logs"; New-Item -ItemType Directory -Force -Path $logd | Out-Null
$log  = "$logd\software-push-all.log"
function L($m){ $s="{0}  {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; $s|Out-File $log -Append -Encoding utf8; Write-Host $s }

L "=== run start (user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)) ==="

# --- installed-detection helpers --------------------------------------------
$appCache = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue |
            Where-Object DisplayName | Select-Object -Expand DisplayName -Unique
function Have($rx){ [bool]($appCache | Where-Object { $_ -match $rx }) }

# --- winget resolution (this user) ------------------------------------------
$winget = (Get-Command winget.exe -EA SilentlyContinue).Source
if (-not $winget) { $winget = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" -EA SilentlyContinue | Select-Object -First 1).FullName }
if (-not $winget) { $p = Get-AppxPackage Microsoft.DesktopAppInstaller -EA SilentlyContinue | Select-Object -First 1; if ($p) { $winget = Join-Path $p.InstallLocation 'winget.exe' } }

$winPkgs = @(
    'Microsoft.VCRedist.2015+.x64','Microsoft.VCRedist.2015+.x86',
    'Google.Chrome','Mozilla.Firefox','Microsoft.RemoteDesktopClient',
    'Git.Git','OpenJS.NodeJS.LTS','Python.Python.3.12','Microsoft.PowerShell',
    'Microsoft.WSL','Ollama.Ollama','Anthropic.Claude'
)

# --- Step 1: winget, launched CONCURRENTLY (only if not already all done) ----
$wingetDone = "$root\markers\winget-push.done"
New-Item -ItemType Directory -Force -Path "$root\markers" | Out-Null
if (Test-Path $wingetDone) {
    L 'winget set already completed (marker present) - skipping'
} elseif (-not $winget) {
    L 'winget not resolvable for this user yet - will retry next run'
} else {
    try { & $winget source update --disable-interactivity 2>&1 | Out-Null } catch {}
    $wl = "$logd\winget"; New-Item -ItemType Directory -Force -Path $wl | Out-Null
    $procs = @()
    foreach ($id in $winPkgs) {
        $inner = @"
`$a=@('install','--id','$id','--exact','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
`$p=Start-Process '$winget' -ArgumentList (`$a+@('--scope','machine')) -Wait -PassThru -NoNewWindow
if(`$p.ExitCode -notin 0,-1978335189,-1978335135){`$p=Start-Process '$winget' -ArgumentList `$a -Wait -PassThru -NoNewWindow}
"[$id] exit=`$(`$p.ExitCode)"|Out-File '$wl\$(( $id -replace '[^\w\.\+]','_')).log' -Encoding utf8
exit `$p.ExitCode
"@
        $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        $procs += (Start-Process powershell.exe -ArgumentList @('-NoProfile','-EncodedCommand',$enc) -PassThru -WindowStyle Hidden)
        L "  launched winget $id (pid $($procs[-1].Id))"
    }
    L "  waiting for $($procs.Count) concurrent winget installs..."
    $procs | Wait-Process -Timeout 1800 -EA SilentlyContinue
    # re-scan; if the core apps are present, mark winget done
    $appCache = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue | Where-Object DisplayName | Select-Object -Expand DisplayName -Unique
    $core = @('Google Chrome','Git','Python','PowerShell 7')
    $missing = @($core | Where-Object { -not (Have ([regex]::Escape($_))) })
    if ($missing.Count -eq 0) { New-Item -ItemType File -Force -Path $wingetDone | Out-Null; L '  winget core set installed -> marker written' }
    else { L "  winget still missing: $($missing -join ', ') (will retry next run)" }
}

# --- Step 2: deployables (Office, Mastercam) - execute locally ---------------
function Run-Deployable([string]$name,[string]$url,[string]$doneRx){
    if (Have $doneRx) { L "  $name already installed - skipping"; return }
    L "  fetching + running $name ..."
    try {
        $tmp = Join-Path $env:TEMP $name
        Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing -TimeoutSec 90
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp *>&1 | ForEach-Object { L "    $_" }
        Remove-Item $tmp -Force -EA SilentlyContinue
    } catch { L "    ERROR ${name}: $($_.Exception.Message)" }
}
Run-Deployable 'office365-install.ps1'    "$ApiBase/static/pkgs/office365-install.ps1"    'Microsoft 365|Office'
Run-Deployable 'mastercam2026-install.ps1' "$ApiBase/static/pkgs/mastercam2026-install.ps1" 'Mastercam'

# --- Step 3: refresh agent so inventory reflects the new software ------------
try { Invoke-RestMethod "$ApiBase/static/install_agent.ps1" -TimeoutSec 30 | Invoke-Expression; L '  agent registration refreshed' } catch { L "  agent refresh err: $($_.Exception.Message)" }

# --- Step 4: self-complete: if everything is present, stop repeating ---------
$appCache = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue | Where-Object DisplayName | Select-Object -Expand DisplayName -Unique
$allDone = (Test-Path $wingetDone) -and (Have 'Microsoft 365|Office') -and (Have 'Mastercam')
if ($allDone) {
    L 'ALL software present -> removing repeating trigger (task will not run again)'
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -EA Stop
        # keep an at-logon trigger off; drop all triggers so it stops firing
        $t.Triggers = @()
        Set-ScheduledTask -TaskName $TaskName -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)) -EA SilentlyContinue | Out-Null
    } catch {}
    New-Item -ItemType File -Force -Path "$root\markers\software-push.done" | Out-Null
} else {
    L 'not all software present yet - will run again on next trigger'
}
L '=== run end ==='
