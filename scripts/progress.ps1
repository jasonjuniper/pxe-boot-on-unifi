# progress.ps1 - Juniper Imaging shared progress helper
# ---------------------------------------------------------------------------
# Dot-source this from a phase script (and/or the orchestrator) to publish
# GRANULAR, live provisioning progress that the kiosk status screen
# (provision-status.ps1) and the inventory Imaging tab (/deploy/status) both
# read.  It does TWO things on every call, both best-effort (never throws):
#
#   1. Writes C:\ProgramData\JuniperSetup\progress.json atomically (.tmp + move)
#      so the kiosk GUI - which polls it ~every 1.5s - never reads a half file.
#   2. POSTs the same snapshot to the inventory server /ingest/deploy-progress
#      so the same device_provisioning row updates live on /deploy/status.
#
# Why this exists: the orchestrator only updates progress at phase TRANSITIONS.
# The windows-update phase runs for a long time across many reboots, so without
# the phase script itself reporting, the card sits frozen at the band start with
# an empty step message and a stale updatedUtc.  This helper lets the phase
# report per-update detail ("Round 2 - installing 3 of 8: <KB>") frequently.
#
# Device identity (serial -> mac -> hostname) is resolved the SAME way the
# orchestrator does so the server keys the SAME device_provisioning row whether
# the orchestrator or a phase script posts.  ASCII-safe, UTF8 (no BOM).

$Script:ProgSetupRoot   = 'C:\ProgramData\JuniperSetup'
$Script:ProgFile        = "$Script:ProgSetupRoot\progress.json"
$Script:ProgInvApi      = 'http://192.168.5.141:8080'
$Script:ProgIdentity    = $null

# Phase bands (overallPercent slice each phase owns of the 0-100 bar) - MUST
# match $PhaseMeta in orchestrator.ps1 so the bar stays monotonic across the
# orchestrator's transition writes and the phase script's in-band writes.
$Script:ProgPhaseBands = @{
    'windows-update'    = @{ Start = 5;  End = 45 }
    'install-packages'  = @{ Start = 45; End = 72 }
    'join-wifi'         = @{ Start = 72; End = 78 }
    'remove-bloatware'  = @{ Start = 78; End = 90 }
    'file-associations' = @{ Start = 90; End = 99 }
}

# Cache machine identity once (serial + hostname + primary MAC). Mirrors
# orchestrator.ps1 Get-MachineIdentity so the server resolves the same record.
function Get-ProgIdentity {
    if ($Script:ProgIdentity) { return $Script:ProgIdentity }
    $serial = $null; $mac = $null
    try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber } catch {}
    try {
        $nic = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
               Where-Object { $_.PhysicalAdapter -and $_.MACAddress -and $_.NetEnabled } |
               Select-Object -First 1
        if (-not $nic) {
            $nic = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.PhysicalAdapter -and $_.MACAddress } | Select-Object -First 1
        }
        if ($nic) { $mac = $nic.MACAddress }
    } catch {}
    $Script:ProgIdentity = [pscustomobject]@{
        serial   = if ($serial) { "$serial".Trim() } else { $null }
        hostname = $env:COMPUTERNAME
        mac      = if ($mac) { "$mac".Replace('-',':').ToLower() } else { $null }
    }
    return $Script:ProgIdentity
}

# Map a phase key + fraction (0..1 within the phase) to an absolute overall
# percent within that phase's band.  Use this when the caller wants to express
# progress as "how far through this phase" rather than an absolute percent.
function Get-ProgBandPercent {
    param([string]$PhaseKey, [double]$Fraction = 0.0)
    if (-not $Script:ProgPhaseBands.ContainsKey($PhaseKey)) { return 5 }
    $b = $Script:ProgPhaseBands[$PhaseKey]
    $f = [math]::Max(0.0, [math]::Min(1.0, $Fraction))
    return [int][math]::Round($b.Start + ($b.End - $b.Start) * $f)
}

# Publish one progress snapshot. Always stamps updatedUtc (ISO-8601 UTC) so a
# frozen timestamp on the dashboard visibly flags a stuck machine. Best-effort:
# a file-lock or an unreachable server NEVER blocks/aborts the calling phase.
function Publish-Progress {
    param(
        [Parameter(Mandatory)][string]$PhaseKey,
        [Parameter(Mandatory)][string]$PhaseLabel,
        [Parameter(Mandatory)][int]$OverallPercent,
        [string]$StepMessage = '',
        [int]$PhaseIndex = 1,
        [int]$PhaseTotal = 5,
        [ValidateSet('running','rebooting','done','error')][string]$State = 'running',
        [string]$Source = 'phase'
    )
    $pct = [int]$OverallPercent
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }

    $obj = [ordered]@{
        overallPercent = $pct
        phaseKey       = $PhaseKey
        phaseLabel     = $PhaseLabel
        phaseIndex     = [int]$PhaseIndex
        phaseTotal     = [int]$PhaseTotal
        stepMessage    = $StepMessage
        state          = $State
        updatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    # 1) progress.json (atomic: write .tmp then move into place).
    $json = $obj | ConvertTo-Json -Compress
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $tmp = "$Script:ProgFile.tmp"
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item $tmp $Script:ProgFile -Force -ErrorAction Stop
            break
        } catch { Start-Sleep -Milliseconds 150 }
    }

    # 2) POST to the inventory server (best-effort, short timeout).
    try {
        $id = Get-ProgIdentity
        $body = @{
            serial         = $id.serial
            hostname       = $id.hostname
            mac            = $id.mac
            overallPercent = $pct
            phaseKey       = $PhaseKey
            phaseLabel     = $PhaseLabel
            phaseIndex     = [int]$PhaseIndex
            phaseTotal     = [int]$PhaseTotal
            stepMessage    = $StepMessage
            state          = $State
            updatedUtc     = $obj.updatedUtc
            source         = $Source
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Script:ProgInvApi/ingest/deploy-progress" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 5 -ErrorAction Stop | Out-Null
    } catch {}
}
