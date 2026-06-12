# deploy-boot.ps1 — WinPE bootstrap
#
# Baked into the WinPE image at X:\Windows\System32\deploy-boot.ps1.
# Launched by startnet.cmd after wpeinit.
#
# PURPOSE: Wait for network, map the deploy share, and run the live
# deploy.ps1 from the share.  Keeping the main logic on the share means
# script changes do NOT require a WIM rebuild — only changes to this
# file (or startnet.cmd) require a rebuild.
#
# Press T within 5 seconds at startup to open the diagnostic toolkit instead.

$DeployServer = '192.168.5.141'   # pc-deploy — use IP; DNS may not work in WinPE
$DeployShare  = "\\$DeployServer\deploy$"

Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Juniper Design  -  PC Deployment System  ' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Press [T] within 5 seconds to open the diagnostic toolkit.' -ForegroundColor DarkGray
Write-Host '  Any other key or timeout continues to deployment.' -ForegroundColor DarkGray
Write-Host ''

# ── Toolkit intercept (5-second window) ──────────────────────────────────────
$launchToolkit = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 5000) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::T) { $launchToolkit = $true }
        break
    }
    Start-Sleep -Milliseconds 100
}
$sw.Stop()

if ($launchToolkit) {
    Write-Host '  Opening toolkit...' -ForegroundColor Cyan
    & X:\Windows\System32\toolkit.ps1
    exit
}

# ── Wait for network ──────────────────────────────────────────────────────────
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

# ── Map deploy share ──────────────────────────────────────────────────────────
try { net use $DeployShare /persistent:no *>$null } catch {}

if (-not (Test-Path $DeployShare)) {
    Write-Host "  Cannot reach $DeployShare" -ForegroundColor Red
    Write-Host '  Verify deploy$ share is accessible from WinPE (Everyone:Read).' -ForegroundColor Yellow
    Write-Host '  Run 01a-enable-remote-access.ps1 and 01d-setup-deploy-share.ps1 on pc-deploy.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
    exit
}

# ── Run live deploy.ps1 from share ───────────────────────────────────────────
$liveScript = "$DeployShare\scripts\deploy.ps1"
if (Test-Path $liveScript) {
    & $liveScript
} else {
    Write-Host ''
    Write-Host "  ERROR: $liveScript not found on deploy share." -ForegroundColor Red
    Write-Host '  Run 01d-setup-deploy-share.ps1 on pc-deploy to populate the share.' -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'
    wpeutil reboot
}
