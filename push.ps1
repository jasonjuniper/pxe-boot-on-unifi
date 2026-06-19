# push.ps1 - thin wrapper -> master dev-push orchestrator.
# Canonical master: GitLab automation/dev-push-automation (cloned to
# C:\dev\dev-push-automation). Runs the full branded push pipeline (PDF gen,
# commit, destination-correct push, SharePoint sync where applicable) for THIS
# repo only. Any extra args (e.g. -DryRun) pass straight through.
$ErrorActionPreference = 'Stop'
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
