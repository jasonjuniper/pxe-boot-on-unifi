# orchestrator.ps1 - Juniper Imaging Phase Orchestrator
# Runs as SYSTEM via the JuniperImaging scheduled task (created by SetupComplete.cmd).
# Reads phase.json to determine what to run next, executes the phase script,
# logs the result, advances state, and reboots if needed.
#
# Lifecycle:
#   SetupComplete.cmd --> orchestrator.ps1 -Bootstrap
#     --> creates JuniperImaging scheduled task (AtStartup, SYSTEM)
#     --> writes initial phase.json
#     --> runs first phase immediately
#   Each subsequent boot:
#     JuniperImaging task --> orchestrator.ps1
#       --> reads current phase --> runs phase script --> logs exit code
#       --> exit 3010: reboot (phase stays same, task fires again next boot)
#       --> exit 0:    advance to next phase, run it now (no reboot needed)
#       --> all phases done: remove task, done
#
# Logs:
#   C:\ProgramData\JuniperSetup\imaging.log       master log
#   C:\ProgramData\JuniperSetup\logs\<phase>.log  per-phase output

param([switch]$Bootstrap)

$SetupRoot  = 'C:\ProgramData\JuniperSetup'
$ScriptsDir = "$SetupRoot\scripts"
$PhaseFile  = "$SetupRoot\phase.json"
$TaskName   = 'JuniperImaging'

# Phase order: key matches phase.json "phase", value is script filename in $ScriptsDir
$Phases = [ordered]@{
    'windows-update'    = '03-windows-update.ps1'
    'install-packages'  = '04-install-packages.ps1'
    'remove-bloatware'  = '07-remove-bloatware.ps1'
    'file-associations' = '08-set-file-associations.ps1'
}

. "$SetupRoot\Logging.ps1"
Initialize-ImagingLogging -PhaseName 'orchestrator'

# ---- Helpers ----------------------------------------------------------------

function Get-PhaseState {
    if (Test-Path $PhaseFile) {
        try { return Get-Content $PhaseFile -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ phase = 'windows-update'; round = 0 }
}

function Save-PhaseState {
    param([string]$Phase, [int]$Round = 0)
    [pscustomobject]@{
        phase   = $Phase
        round   = $Round
        updated = (Get-Date -Format 'o')
    } | ConvertTo-Json | Set-Content $PhaseFile -Encoding UTF8
}

function Get-NextPhase {
    param([string]$Current)
    $keys = @($Phases.Keys)
    $idx  = [array]::IndexOf($keys, $Current)
    if ($idx -lt 0 -or $idx -ge $keys.Count - 1) { return 'done' }
    return $keys[$idx + 1]
}

function Invoke-Phase {
    param([string]$PhaseName)

    $script = Join-Path $ScriptsDir $Phases[$PhaseName]
    if (-not (Test-Path $script)) {
        Write-Log "Script missing: $script - skipping phase '$PhaseName'" -Level WARN
        return 0   # treat as success so imaging continues
    }

    $outFile = "$SetupRoot\logs\$PhaseName-raw.txt"
    $errFile = "$SetupRoot\logs\$PhaseName-err.txt"

    Write-Log "Executing: $script"

    $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`"" `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile

    # Append captured output into the phase log
    $phaseLog = "$SetupRoot\logs\$PhaseName.log"
    if (Test-Path $outFile) {
        Get-Content $outFile | Add-Content -LiteralPath $phaseLog -Encoding UTF8 -ErrorAction SilentlyContinue
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $errFile) {
        $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($errText -and $errText.Trim()) {
            Add-Content -LiteralPath $phaseLog -Value '--- STDERR ---' -Encoding UTF8 -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $phaseLog -Value $errText         -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    return $p.ExitCode
}

function Sync-Scripts {
    # Pulls fresh phase scripts from the deploy share before running each phase.
    # Allows hotfixing phase scripts without re-imaging the machine.
    # Silently skipped if the share is unreachable.
    $shareScripts = '\\192.168.5.141\deploy$\scripts'
    if (-not (Test-Path $shareScripts -ErrorAction SilentlyContinue)) { return }
    try {
        # Phase scripts go into $ScriptsDir
        foreach ($f in $Phases.Values) {
            $src = Join-Path $shareScripts $f
            $dst = Join-Path $ScriptsDir $f
            if (Test-Path $src) {
                Copy-Item $src $dst -Force -ErrorAction SilentlyContinue
            }
        }
        # Logging.ps1 lives at $SetupRoot (dot-sourced directly by each phase script)
        $logSrc = Join-Path $shareScripts 'Logging.ps1'
        if (Test-Path $logSrc) {
            Copy-Item $logSrc "$SetupRoot\Logging.ps1" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    # No Write-Log here - Logging.ps1 may have just been replaced
}

# ---- Bootstrap: first call from SetupComplete.cmd ---------------------------

if ($Bootstrap) {
    Write-Log "=== Juniper Imaging Orchestrator v1.0 - $env:COMPUTERNAME ===" -MasterOnly
    Write-Log "Bootstrap started on $env:COMPUTERNAME"

    # Create the JuniperImaging scheduled task (fires on every startup, SYSTEM)
    $action    = New-ScheduledTaskAction `
                    -Execute 'powershell.exe' `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SetupRoot\orchestrator.ps1`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -RestartCount 0

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Juniper IT post-imaging automated setup' -Force | Out-Null

    Write-Log "Scheduled task '$TaskName' registered (AtStartup, SYSTEM)"

    # Set all network connections to Private so WinRM cross-subnet access works.
    # Without this, Windows leaves new connections as Public, which restricts
    # the WinRM firewall rule to same-subnet only.
    try {
        Get-NetConnectionProfile |
            Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' } |
            Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
        Write-Log "Network profile set to Private" -MasterOnly
    } catch {
        Write-Log "Network profile update failed (non-fatal): $_" -Level WARN -MasterOnly
    }

    # Enable WinRM so IT can reach the machine remotely during and after imaging.
    # -SkipNetworkProfileCheck allows it even when the NIC profile is Public.
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
        # Trust the imaging subnet so IT workstations can connect without extra config
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.0.*,192.168.1.*,192.168.2.*,192.168.3.*,192.168.4.*,192.168.5.*,192.168.6.*,192.168.7.*,192.168.8.*,192.168.9.*,192.168.10.*' `
            -Force -ErrorAction SilentlyContinue
        Write-Log "WinRM enabled (PSRemoting active)" -MasterOnly
    } catch {
        Write-Log "WinRM enable failed (non-fatal): $_" -Level WARN -MasterOnly
    }

    # Write initial phase state if not already present
    if (-not (Test-Path $PhaseFile)) {
        Save-PhaseState -Phase 'windows-update' -Round 0
        Write-Log "Phase state initialized: windows-update" -MasterOnly
    }

    # Change junadmin password immediately so CHANGEME is not live during imaging.
    # The bootstrap API returns the same password that 04-install-packages.ps1 will set,
    # so this just moves that step to the very first boot (before the login screen is usable).
    try {
        $invApi   = 'http://192.168.5.141:8080'
        $resp     = Invoke-RestMethod "$invApi/api/management/bootstrap" -TimeoutSec 10 -ErrorAction Stop
        $bPass    = $resp.password
        if ($bPass) {
            $secPass = ConvertTo-SecureString $bPass -AsPlainText -Force
            Set-LocalUser -Name 'junadmin' -Password $secPass -ErrorAction Stop
            $secPass = $null; $bPass = $null; $resp = $null
            Write-Log "junadmin password updated from bootstrap API" -MasterOnly
        }
    } catch {
        Write-Log "Could not update junadmin password at bootstrap: $_ (CHANGEME still active)" -Level WARN -MasterOnly
    }

    Write-Log "Bootstrap complete - proceeding to first phase"
    # Fall through to main execution block below
}

# ---- Main: run current phase ------------------------------------------------

$state = Get-PhaseState
$phase = $state.phase

if ($phase -eq 'done') {
    Write-Log "=== All imaging phases complete on $env:COMPUTERNAME ===" -MasterOnly
    Write-Log "All phases complete - removing scheduled task"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

if (-not $Phases.Contains($phase)) {
    Write-Log "Unknown phase '$phase' - resetting to windows-update" -Level WARN
    $phase = 'windows-update'
}

$round = [int]($state.round) + 1
Save-PhaseState -Phase $phase -Round $round
Write-Log "--- Phase: $phase (round $round) ---" -MasterOnly
Write-Log "Starting phase '$phase' (round $round)"

Sync-Scripts
$exitCode = Invoke-Phase -PhaseName $phase

Write-Log "Phase '$phase' exited: $exitCode"

if ($exitCode -eq 3010) {
    # Phase installed updates and needs a reboot - phase stays the same
    Write-Log "Reboot required after phase '$phase' round $round - rebooting now" -MasterOnly
    Write-Log "Rebooting in 10 seconds..."
    Start-Sleep 10
    Restart-Computer -Force

} elseif ($exitCode -eq 0) {
    # Phase complete - advance and immediately run next phase
    $nextPhase = Get-NextPhase -Current $phase
    Write-Log "Phase '$phase' succeeded - advancing to '$nextPhase'" -MasterOnly
    Write-Log "Advancing to '$nextPhase'"
    Save-PhaseState -Phase $nextPhase -Round 0

    if ($nextPhase -eq 'done') {
        Write-Log "=== Imaging complete on $env:COMPUTERNAME - all phases succeeded ===" -MasterOnly
        Write-Log "All phases done. Removing scheduled task."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        # Run next phase in this same session (no reboot needed)
        $round2 = 1
        Save-PhaseState -Phase $nextPhase -Round $round2
        Write-Log "--- Phase: $nextPhase (round $round2) ---" -MasterOnly
        Write-Log "Starting phase '$nextPhase' (round $round2)"
        Sync-Scripts
        $exitCode2 = Invoke-Phase -PhaseName $nextPhase
        Write-Log "Phase '$nextPhase' exited: $exitCode2" -MasterOnly

        if ($exitCode2 -eq 3010) {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Write-Log "Reboot required after '$nextPhase' - rebooting, will continue at '$next2'" -MasterOnly
            Start-Sleep 10
            Restart-Computer -Force
        } elseif ($exitCode2 -eq 0) {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Write-Log "Phase '$nextPhase' succeeded - next phase '$next2' will run on next scheduled trigger" -MasterOnly
        } else {
            $next2 = Get-NextPhase -Current $nextPhase
            Save-PhaseState -Phase $next2 -Round 0
            Write-Log "Phase '$nextPhase' exited $exitCode2 (non-fatal) - continuing to '$next2'" -Level WARN -MasterOnly
        }
    }

} else {
    # Non-zero, non-3010: log the error but advance so imaging doesn't stall
    $nextPhase = Get-NextPhase -Current $phase
    Write-Log "Phase '$phase' exited $exitCode (non-fatal error) - advancing to '$nextPhase'" -Level WARN -MasterOnly
    Write-Log "Phase '$phase' non-fatal error (exit=$exitCode) - continuing" -Level WARN
    Save-PhaseState -Phase $nextPhase -Round 0
}
