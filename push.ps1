# push.ps1 - thin wrapper -> master dev-push orchestrator.
# Canonical master: GitLab automation/dev-push-automation (cloned to
# C:\dev\dev-push-automation). Runs the full branded push pipeline (PDF gen,
# commit, destination-correct push, SharePoint sync where applicable) for THIS
# repo only. Any extra args (e.g. -DryRun) pass straight through.
$ErrorActionPreference = 'Stop'

# --- Sync check: install_agent.ps1 -------------------------------------------
# The live copy on pc-deploy is the source of truth. If it differs from the
# repo copy, auto-pull it so we never push a stale agent.
$agentRepo   = Join-Path $PSScriptRoot 'scripts\static\install_agent.ps1'
$deployHost  = '192.168.5.141'
$agentRemote = 'C:\inventory\app\static\install_agent.ps1'

try {
    $session = New-PSSession -ComputerName $deployHost -ErrorAction Stop
    $liveBytes = Invoke-Command -Session $session -ScriptBlock {
        param($p) [System.IO.File]::ReadAllBytes($p)
    } -ArgumentList $agentRemote
    Remove-PSSession $session

    $repoHash = (Get-FileHash $agentRepo -Algorithm MD5).Hash
    $liveHash = [System.Security.Cryptography.MD5]::Create().ComputeHash($liveBytes) |
        ForEach-Object { $_.ToString('x2') }
    $liveHashStr = -join $liveHash

    if ($repoHash -ne $liveHashStr) {
        Write-Host ''
        Write-Host '  [sync] install_agent.ps1 differs from live server -- pulling before push.' -ForegroundColor Yellow
        [System.IO.File]::WriteAllBytes($agentRepo, $liveBytes)
        Write-Host "  [sync] Updated ($([math]::Round($liveBytes.Length/1KB,1)) KB)" -ForegroundColor Green
    }
} catch {
    Write-Host "  [sync] Could not reach $deployHost to check install_agent.ps1 -- skipping sync check." -ForegroundColor DarkGray
}

# --- Sync check: JuniperInventoryAgent.msi + .json ---------------------------
$msiRepo    = Join-Path $PSScriptRoot 'scripts\static\JuniperInventoryAgent.msi'
$jsonRepo   = Join-Path $PSScriptRoot 'scripts\static\JuniperInventoryAgent.json'
$msiRemote  = 'C:\inventory\app\static\JuniperInventoryAgent.msi'
$jsonRemote = 'C:\inventory\app\static\JuniperInventoryAgent.json'

try {
    $session2 = New-PSSession -ComputerName $deployHost -ErrorAction Stop

    # Sync JSON (small - always pull)
    $liveJson = Invoke-Command -Session $session2 -ScriptBlock {
        param($p) if (Test-Path $p) { Get-Content $p -Raw } else { $null }
    } -ArgumentList $jsonRemote
    if ($liveJson) {
        $liveVer  = ($liveJson | ConvertFrom-Json).agent_version
        $repoVer  = if (Test-Path $jsonRepo) { (Get-Content $jsonRepo -Raw | ConvertFrom-Json).agent_version } else { $null }
        if ($liveVer -ne $repoVer) {
            Write-Host "  [sync] MSI version changed ($repoVer -> $liveVer) -- pulling MSI + JSON." -ForegroundColor Yellow
            Set-Content $jsonRepo $liveJson -Encoding ASCII

            # MSI is large - only pull when version changes
            $liveBytes = Invoke-Command -Session $session2 -ScriptBlock {
                param($p) if (Test-Path $p) { [System.IO.File]::ReadAllBytes($p) } else { $null }
            } -ArgumentList $msiRemote
            if ($liveBytes) {
                [System.IO.File]::WriteAllBytes($msiRepo, $liveBytes)
                Write-Host "  [sync] MSI updated ($([math]::Round($liveBytes.Length/1KB,1)) KB)" -ForegroundColor Green
            }
        }
    }
    Remove-PSSession $session2
} catch {
    Write-Host "  [sync] Could not sync MSI/JSON from $deployHost -- skipping." -ForegroundColor DarkGray
}
# -----------------------------------------------------------------------------
$master = $env:DEV_PUSH_AUTOMATION
if (-not $master) { $master = 'C:\dev\dev-push-automation\push-all.ps1' }
if (-not (Test-Path $master)) {
    Write-Host "X master push script not found at $master" -ForegroundColor Red
    Write-Host "  Set `$env:DEV_PUSH_AUTOMATION, or clone automation/dev-push-automation to C:\dev." -ForegroundColor Yellow
    exit 1
}
$thisRepo = Split-Path $PSScriptRoot -Leaf
& $master -Only $thisRepo @args
exit $LASTEXITCODE
