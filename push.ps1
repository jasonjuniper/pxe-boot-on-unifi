# pxe-boot-on-unifi - push automation
# Usage: .\push.ps1           -- full pipeline: commit + PDF regen + push
#        .\push.ps1 -DryRun   -- preview only
param([switch]$DryRun)
$master = "C:\dev\dev-push-automation\push-all.ps1"
if (-not (Test-Path $master)) { throw "Master push script not found: $master" }
$callArgs = @($PSScriptRoot)
if ($DryRun) { $callArgs += "-DryRun" }
& $master @callArgs
