#Requires -Version 5.1
<#
build-driver-library.ps1
--------------------------------------------------------------------------------
Fleet driver-library builder. For every target machine type it runs the full
Lenovo pipeline end-to-end:

    build-lenovo-manifest.ps1  (catalog -> <MT>-driver-manifest.json)
  -> sync-lenovo-drivers.ps1   (manifest -> DB rows, unconfirmed)
  -> curate-lenovo-model.ps1   (download + silent extract + keep .inf)
  -> promote-lenovo-model.ps1  (confirmed_working + backfill sha + manifest.json)

Targets come from a JSON file (default C:\deploy\scripts\driver-library-targets.json):
    [ { "mt": "83JU", "slug": "lenovo-yoga-7-16akp10", "model": "Yoga 7 2-in-1 16AKP10" }, ... ]

Runs sequentially (each curate pulls ~0.5-2 GB), logging to
C:\deploy\_staging\driver-library.log. Best-effort per target: one model failing
never aborts the rest. Intended to run as a SYSTEM scheduled task.

    .\build-driver-library.ps1                       # all targets
    .\build-driver-library.ps1 -OnlyMt 20Y3,82YN     # subset
    .\build-driver-library.ps1 -SkipCurate           # manifests + DB rows only
--------------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [string]   $TargetsPath = 'C:\deploy\scripts\driver-library-targets.json',
    [string]   $Os          = 'Win11',
    [string[]] $OnlyMt,
    [switch]   $SkipCurate
)
$ErrorActionPreference = 'Stop'
$scripts = 'C:\deploy\scripts'
$log = 'C:\deploy\_staging\driver-library.log'
New-Item -ItemType Directory -Force -Path 'C:\deploy\_staging' | Out-Null
function L([string]$m){ $ts=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; "$ts  $m" | Tee-Object -FilePath $log -Append | Out-Null }

if (-not (Test-Path $TargetsPath)) { throw "Targets file not found: $TargetsPath" }
$targets = Get-Content $TargetsPath -Raw | ConvertFrom-Json
L "=== build-driver-library START ($($targets.Count) targets, Os=$Os, SkipCurate=$SkipCurate) ==="

foreach ($t in $targets) {
    if ($OnlyMt -and ($t.mt -notin $OnlyMt)) { continue }
    L "---- $($t.mt) ($($t.slug) / $($t.model)) START ----"
    try {
        & "$scripts\build-lenovo-manifest.ps1" -MachineType $t.mt -Os $Os -ThrottleMs 0 *>> $log
        & "$scripts\sync-lenovo-drivers.ps1" -ManifestPath "$scripts\$($t.mt)-driver-manifest.json" `
            -Model $t.model -MachineType $t.mt -DriverRoot $t.slug -Os 'Windows 11' *>> $log
        if (-not $SkipCurate) {
            & "$scripts\curate-lenovo-model.ps1"  -MachineType $t.mt -Slug $t.slug *>> $log
            & "$scripts\promote-lenovo-model.ps1" -MachineType $t.mt -Slug $t.slug *>> $log
        }
        L "---- $($t.mt) DONE ----"
    } catch {
        L "---- $($t.mt) ERROR: $($_.Exception.Message) ----"
    }
}
L "=== build-driver-library COMPLETE ==="
