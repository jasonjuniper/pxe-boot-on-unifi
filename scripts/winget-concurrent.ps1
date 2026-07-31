# winget-concurrent.ps1
# Installs the standard 12-package winget set CONCURRENTLY. Must run as a real
# user (junadmin) - winget cannot run as SYSTEM. Each package installs in its
# own process; Windows Installer's global mutex naturally serialises the MSI
# ones while exe/portable packages proceed in parallel.
param(
    [string]$LogDir = 'C:\ProgramData\JuniperSetup\logs\winget'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$master = Join-Path $LogDir '_winget-concurrent.log'
function L($m){ $s="{0}  {1}" -f (Get-Date -f 'HH:mm:ss'),$m; $s|Out-File $master -Append -Encoding utf8; Write-Host $s }

$pkgs = @(
    'Microsoft.VCRedist.2015+.x64','Microsoft.VCRedist.2015+.x86',
    'Google.Chrome','Mozilla.Firefox','Microsoft.RemoteDesktopClient',
    'Git.Git','OpenJS.NodeJS.LTS','Python.Python.3.12','Microsoft.PowerShell',
    'Microsoft.WSL','Ollama.Ollama','Anthropic.Claude'
)

# resolve winget for THIS user
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) { $winget = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" -EA SilentlyContinue | Select-Object -First 1).FullName }
if (-not $winget) { $p = Get-AppxPackage Microsoft.DesktopAppInstaller -EA SilentlyContinue | Select-Object -First 1; if ($p) { $winget = Join-Path $p.InstallLocation 'winget.exe' } }
L "user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)  winget=$winget"
if (-not $winget) { L 'FATAL: winget not found for this user'; exit 1 }

try { & $winget source update --disable-interactivity 2>&1 | Out-Null } catch {}

# launch all installs CONCURRENTLY (no -Wait); each tries machine scope then user
$procs = @()
foreach ($id in $pkgs) {
    $safe = ($id -replace '[^\w\.\+]','_')
    $out  = Join-Path $LogDir "$safe.log"
    $inner = @"
`$w = '$winget'
`$a = @('install','--id','$id','--exact','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
`$p = Start-Process `$w -ArgumentList (`$a + @('--scope','machine')) -Wait -PassThru -NoNewWindow
if (`$p.ExitCode -notin 0,-1978335189,-1978335135) { `$p = Start-Process `$w -ArgumentList `$a -Wait -PassThru -NoNewWindow }
"[$id] exit=`$(`$p.ExitCode)" | Out-File '$out' -Append -Encoding utf8
exit `$p.ExitCode
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $pr = Start-Process powershell.exe -ArgumentList @('-NoProfile','-EncodedCommand',$enc) -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Id=$id; Proc=$pr; Log=$out }
    L "launched $id (pid $($pr.Id))"
}

L "all $($procs.Count) installs launched concurrently - waiting..."
$procs | ForEach-Object { $_.Proc } | Wait-Process -Timeout 2400 -ErrorAction SilentlyContinue

L '=== results ==='
foreach ($x in $procs) {
    $code = try { $x.Proc.ExitCode } catch { 'running/unknown' }
    $ok = ($code -in 0,-1978335189,-1978335135)
    L ("  {0,-34} exit={1} {2}" -f $x.Id, $code, $(if($ok){'OK'}elseif($code -eq 'running/unknown'){'?'}else{'FAIL'}))
}
L '=== winget concurrent push done ==='
