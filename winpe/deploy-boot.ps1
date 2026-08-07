# deploy-boot.ps1 -- WinPE bootstrap
#
# Baked into the WinPE image at X:\Windows\System32\deploy-boot.ps1.
# Launched by startnet.cmd after wpeinit.
#
# PURPOSE: Wait for network, map the deploy share, and run the live
# deploy.ps1 from the share, fronted by the branded WPF imaging screen.
# Keeping the main logic on the share means script changes do NOT require a
# WIM rebuild -- only changes to this file (or startnet.cmd, deploy-screen.ps1,
# brand-fonts) require a rebuild.
#
# Press T within 60 seconds at startup to open the diagnostic toolkit.
# Press D to skip the wait and deploy immediately.

$DeployServer = '192.168.5.141'   # pc-deploy -- use IP; DNS may not work in WinPE
$DeployShare  = "\\$DeployServer\deploy$"

Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Juniper Design  -  PC Deployment System  ' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Press [T] to open the diagnostic toolkit.' -ForegroundColor DarkGray
Write-Host '  Press [D] to skip the wait and deploy now.' -ForegroundColor DarkGray
Write-Host '  Timeout in 60 seconds continues to deployment.' -ForegroundColor DarkGray
Write-Host ''

# -- Intercept window (60 seconds) --------------------------------------------
$launchToolkit = $false
$deployNow     = $false
$timeoutMs     = 60000
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastSec = -1
while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::T) { $launchToolkit = $true; break }
        if ($key.Key -eq [ConsoleKey]::D) { $deployNow     = $true;  break }
        break
    }
    $secsLeft = [int](($timeoutMs - $sw.ElapsedMilliseconds) / 1000)
    if ($secsLeft -ne $lastSec) {
        $lastSec = $secsLeft
        Write-Host "`r  Deploying in $secsLeft s ...  [T]=Toolkit  [D]=Deploy now  " -NoNewline
    }
    Start-Sleep -Milliseconds 100
}
$sw.Stop()
Write-Host ''

if ($launchToolkit) {
    Write-Host '  Opening toolkit...' -ForegroundColor Cyan
    & X:\Windows\System32\toolkit.ps1
    exit
}

if ($deployNow) {
    Write-Host '  Deploying now...' -ForegroundColor Green
}

# -- Wait for network ---------------------------------------------------------
Write-Host '  Waiting for network...' -ForegroundColor Yellow
$connected = $false
for ($i = 1; $i -le 30; $i++) {
    if (Test-Connection $DeployServer -Count 1 -Quiet 2>$null) {
        Write-Host "  Connected to $DeployServer." -ForegroundColor Green
        $connected = $true
        break
    }
    Write-Host "  [$i/30] Retrying in 2 s..."
    Start-Sleep 2
}

if (-not $connected) {
    Write-Host ''
    Write-Host "  Cannot reach $DeployServer. Check network cable / switch." -ForegroundColor Red
    Write-Host ''
    Write-Host '  TIP: Press Ctrl+C and run toolkit.ps1 to diagnose network issues.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# -- Map deploy share (15s timeout -- net use can hang if SMB is blocked) -----
# Credentials below are substituted at WIM build time by the credential bake.
# The placeholder string must never be replaced with a real password in this file.
$DeployUser = 'junadmin'
$DeployPass = '##WINPE_PASS##'
Write-Host "  Connecting to deploy share (15s timeout)..." -ForegroundColor DarkGray
$netJob = Start-Job -ScriptBlock {
    param($share, $user, $pass)
    net use $share /user:$user $pass /persistent:no 2>&1
} -ArgumentList $DeployShare, $DeployUser, $DeployPass
$null = Wait-Job $netJob -Timeout 15
if ($netJob.State -eq 'Running') {
    Stop-Job $netJob
    Remove-Job $netJob -Force
    Write-Host "  Deploy share connection timed out." -ForegroundColor Red
    Write-Host '  Check: SMB port 445 open on pc-deploy' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}
$netOut = Receive-Job $netJob
Remove-Job $netJob -Force
if ($netOut -match 'error|denied|failed') {
    Write-Host "  Deploy share auth failed: $netOut" -ForegroundColor Red
    Write-Host '  WIM may have stale credentials -- rebuild via the credential bake on pc-deploy.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

if (-not (Test-Path $DeployShare)) {
    Write-Host "  Cannot reach $DeployShare" -ForegroundColor Red
    Write-Host '  Run 01d-setup-deploy-share.ps1 on pc-deploy.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# -- Run deploy with the branded WPF imaging screen ---------------------------
# The full-screen branded imaging screen (X:\deploy-screen.ps1, native WPF) is
# shown while deploy.ps1 runs HIDDEN and writes X:\deploy_log.txt, which the
# screen tails to advance its 14 phase ticks. WPF needs WinPE-NetFx +
# WinPE-PowerShell (baked in). If WPF can't load, we cleanly fall back to the
# interactive console deploy -- so a rendering problem can never leave a
# half-imaged disk. NOTE: with the screen in front, deploy.ps1's prompts
# auto-accept the serial/UEFI defaults (re-images resolve by serial); this is
# the unattended on-machine path.
$liveScript = "$DeployShare\scripts\deploy.ps1"
if (-not (Test-Path $liveScript)) {
    Write-Host ''
    Write-Host "  ERROR: $liveScript not found on deploy share." -ForegroundColor Red
    Write-Host '  Run 01d-setup-deploy-share.ps1 on pc-deploy to populate the share.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

$screen = 'X:\deploy-screen.ps1'
$guiOk  = $false
try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; $guiOk = $true } catch {}

if ($guiOk -and (Test-Path $screen)) {
    Write-Host '  Launching branded imaging screen...' -ForegroundColor Cyan
    # deploy.ps1 runs hidden; its log drives the screen.
    $dep = Start-Process 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$liveScript`"")
    try {
        & $screen -DeployPid $dep.Id
    } catch {
        Write-Host "  Imaging screen error ($($_.Exception.Message)) - deploy continues headless." -ForegroundColor Yellow
    }
    if ($dep -and -not $dep.HasExited) { Wait-Process -Id $dep.Id -ErrorAction SilentlyContinue }
} else {
    if (-not $guiOk) { Write-Host '  WPF unavailable - using console deploy.' -ForegroundColor Yellow }
    # Fallback: original interactive console path (unchanged behavior).
    & $liveScript
}
