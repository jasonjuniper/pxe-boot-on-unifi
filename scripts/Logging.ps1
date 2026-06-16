# Logging.ps1 - Juniper Imaging Logging Module
# Dot-source this at the top of each imaging phase script:
#   . 'C:\ProgramData\JuniperSetup\Logging.ps1'
#
# Log layout:
#   C:\ProgramData\JuniperSetup\imaging.log       <- master log (all phases)
#   C:\ProgramData\JuniperSetup\logs\<phase>.log  <- per-phase detail log
#
# Master log format:
#   2026-06-16 11:30:00  [INFO ]  [windows-update        ]  message

$Script:JuniperSetupRoot = 'C:\ProgramData\JuniperSetup'
$Script:JuniperLogsDir   = "$Script:JuniperSetupRoot\logs"
$Script:JuniperMasterLog = "$Script:JuniperSetupRoot\imaging.log"
$Script:JuniperPhaseLog  = $null
$Script:JuniperPhaseName = $null
$Script:JuniperPhaseTs   = $null

# ---- Initialize logging for a phase -----------------------------------------
# Call once at the top of each phase script before writing any logs.
# PhaseName should match the orchestrator phase key (e.g. 'windows-update').

function Initialize-ImagingLogging {
    param([Parameter(Mandatory)][string]$PhaseName)

    $Script:JuniperPhaseName = $PhaseName
    $Script:JuniperPhaseLog  = "$Script:JuniperLogsDir\$PhaseName.log"
    $Script:JuniperPhaseTs   = Get-Date

    foreach ($dir in @($Script:JuniperSetupRoot, $Script:JuniperLogsDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# ---- Core log writer --------------------------------------------------------
# -MasterOnly : write to imaging.log only (not phase log)
# -PhaseOnly  : write to phase log only (not imaging.log)
# Default     : write to both

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO',
        [switch]$MasterOnly,
        [switch]$PhaseOnly
    )

    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $phase = if ($Script:JuniperPhaseName) { $Script:JuniperPhaseName } else { 'system' }
    $entry = "$ts  [$($Level.PadRight(5))]  [$($phase.PadRight(22))]  $Message"

    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'White' } }
    Write-Host $entry -ForegroundColor $color

    if (-not $PhaseOnly) {
        Add-Content -LiteralPath $Script:JuniperMasterLog -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    if (-not $MasterOnly -and $Script:JuniperPhaseLog) {
        Add-Content -LiteralPath $Script:JuniperPhaseLog -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# ---- Phase start/end banners ------------------------------------------------

function Write-PhaseHeader {
    param([string]$Description = '')
    $desc = if ($Description) { $Description } else { $Script:JuniperPhaseName }
    $bar  = '=' * 60
    Write-Log $bar -PhaseOnly
    Write-Log "PHASE START: $desc"
    Write-Log $bar -PhaseOnly
}

function Write-PhaseSummary {
    param(
        [int]$ExitCode    = 0,
        [string]$Notes    = '',
        [switch]$Reboot          # pass when this invocation will reboot
    )
    $elapsed = if ($Script:JuniperPhaseTs) {
        [int](New-TimeSpan -Start $Script:JuniperPhaseTs -End (Get-Date)).TotalMinutes
    } else { 0 }

    if ($Reboot) {
        $status = 'REBOOTING'
        $level  = 'INFO'
    } elseif ($ExitCode -eq 0) {
        $status = 'COMPLETE'
        $level  = 'INFO'
    } else {
        $status = "FAILED (exit=$ExitCode)"
        $level  = 'ERROR'
    }

    $notesStr = if ($Notes) { " | $Notes" } else { '' }
    Write-Log "PHASE END: $status | elapsed=${elapsed}min$notesStr" -Level $level
    Write-Log ('=' * 60) -PhaseOnly
}
