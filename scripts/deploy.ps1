# deploy.ps1 - Juniper Design WinPE Deployment Script
#
# Lives on the DEPLOY SHARE at \\192.168.5.141\deploy$\scripts\deploy.ps1
# Launched by deploy-boot.ps1 (baked into WinPE) after the share is mapped.
#
# To update without rebuilding WinPE: edit this file and copy to pc-deploy:
#   scripts\deploy.ps1 -> C:\deploy\scripts\deploy.ps1 on pc-deploy
#
# AUTOMATION: deploy.ps1 resolves this machine in the inventory API by
# serial number first, then by MAC address.  If recognised, its prior
# hostname and OS pre-fill two INDEPENDENT fields, each with its own
# 10-second auto-accept countdown.  Press any key within 10 s to override
# that field; let it elapse to accept the default.  After both are chosen
# the name + OS are pushed back to inventory (POST /ingest/endpoint) so the
# next re-image remembers them.  Unknown machines always prompt.
#
# OEM KEY: Windows reads the embedded UEFI key from the ACPI MSDM table
# automatically during setup.  04-install-packages.ps1 also calls slmgr
# post-install as belt-and-suspenders.  No extra work needed here.
#
# SHARE LAYOUT (C:\deploy on pc-deploy):
#   images\win11-home.wim        Windows 11 Home (single-edition, index 1)
#   images\win11-pro.wim         Windows 11 Pro  (single-edition, index 1)
#   images\win10.wim             Windows 10 multi-edition ISO (Win10 Pro = index 6)
#   unattend\unattend-win11.xml
#   unattend\unattend-win10.xml
#   scripts\03-07*.ps1           Post-install scripts (run after first logon)

$ErrorActionPreference = 'Stop'

$DeployServer = '192.168.5.141'   # pc-deploy - use IP, DNS may not work in WinPE
$DeployShare  = "\\$DeployServer\deploy$"
$InvApi       = "http://$DeployServer`:8080"

# ---- Append-only event timeline (best-effort) -------------------------------
# progress.ps1 provides Publish-Event / Invoke-Step, which POST substep+failure
# rows to /ingest/deploy-event so the Imaging tab shows a live, remote, step-by-
# step history of exactly what ran and where it broke. In WinPE the helper is
# usually NOT staged at C:\ProgramData\JuniperSetup yet, so also try the script's
# own dir. If neither loads, define safe no-ops so calls can never break imaging.
try { . 'C:\ProgramData\JuniperSetup\progress.ps1' } catch {}
try { . (Join-Path $PSScriptRoot 'progress.ps1') } catch {}
if (-not (Get-Command Publish-Event -ErrorAction SilentlyContinue)) {
    function Publish-Event { param([Parameter(ValueFromRemainingArguments)]$args) }
}
if (-not (Get-Command Invoke-Step -ErrorAction SilentlyContinue)) {
    function Invoke-Step { param([string]$PhaseKey,[string]$Step,[scriptblock]$Script,[int]$Percent=-1,[switch]$Critical)
        try { & $Script; return $true } catch { if ($Critical) { throw }; return $false } }
}

# Write-DeployLog: writes a line to both the target drive AND the remote inventory log.
# Called during the WinPE phase so every step is visible on pc-deploy in real time.
# $Script:WpeTargetName is set once the computer name is known (later in the script).
function Write-DeployLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $name  = if ($Script:WpeTargetName) { $Script:WpeTargetName } else { 'winpe' }
    $entry = "$ts  [$($Level.PadRight(5))]  [winpe                 ]  $Message"

    # Write to target drive if staging paths are known
    if ($Script:WpeMasterLog) {
        Add-Content -LiteralPath $Script:WpeMasterLog -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    if ($Script:WpePhaseLog) {
        Add-Content -LiteralPath $Script:WpePhaseLog  -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    # Mirror to inventory server (fire-and-forget, 2s timeout)
    try {
        $body = [ordered]@{ computer_name = $name; lines = @($entry) } | ConvertTo-Json -Compress
        Invoke-RestMethod "$InvApi/ingest/imaging-log" `
            -Method POST -Body $body -ContentType 'application/json' `
            -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    Write-Host $entry
}

$Script:WpeTargetName = $null   # set after computer name is chosen
$Script:WpeMasterLog  = $null   # set after staging paths are created on target
$Script:WpePhaseLog   = $null

# Machine identity for progress/log reporting - populated once identity is known.
$Script:WpeSerial = $null
$Script:WpeMac    = $null

# Send-WinpeProgress: best-effort coarse WinPE milestone to /ingest/deploy-progress.
# Feeds the SAME device_provisioning record the post-install orchestrator uses, so
# the Imaging tab (/deploy/status) shows the whole lifecycle: WinPE -> post-install
# -> done. Keyed by serial/MAC/hostname (serial-first resolve) so it stitches to the
# record the orchestrator will later update. Never throws - imaging must not depend
# on the server. WinPE-safe (Invoke-RestMethod is available).
function Send-WinpeProgress {
    param(
        [Parameter(Mandatory)][int]$Percent,
        [Parameter(Mandatory)][string]$Label,
        [string]$Step = '',
        [ValidateSet('winpe','error')][string]$State = 'winpe'
    )
    try {
        $body = [ordered]@{
            serial         = $Script:WpeSerial
            hostname       = $Script:WpeTargetName
            mac            = $Script:WpeMac
            overallPercent = $Percent
            phaseKey       = 'winpe'
            phaseLabel     = $Label
            phaseIndex     = 0
            phaseTotal     = 0
            stepMessage    = $Step
            state          = $State
            updatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            source         = 'deploy.ps1'
        } | ConvertTo-Json -Compress
        Invoke-RestMethod "$InvApi/ingest/deploy-progress" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 4 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# Send-WinpeLog: best-effort upload of the WinPE phase log to /ingest/deploy-log.
# Called once at the end of the WinPE phase (status ok) or on a fatal WinPE error.
function Send-WinpeLog {
    param([ValidateSet('ok','error')][string]$Status = 'ok')
    try {
        $logText = ''
        if ($Script:WpePhaseLog -and (Test-Path $Script:WpePhaseLog)) {
            $logText = [IO.File]::ReadAllText($Script:WpePhaseLog)
        } elseif ($Script:WpeMasterLog -and (Test-Path $Script:WpeMasterLog)) {
            $logText = [IO.File]::ReadAllText($Script:WpeMasterLog)
        }
        $body = [ordered]@{
            serial    = $Script:WpeSerial
            hostname  = $Script:WpeTargetName
            mac       = $Script:WpeMac
            phase_key = 'winpe'
            status    = $Status
            log_text  = $logText
            ts        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json -Compress
        Invoke-RestMethod "$InvApi/ingest/deploy-log" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 6 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

$OsOptions = @{
    '1' = @{
        Label    = 'Windows 11 Home'
        WimFile  = 'images\win11-home.wim'
        WimIndex = 1
        Unattend = 'unattend\unattend-win11.xml'
    }
    '2' = @{
        Label    = 'Windows 11 Pro'
        WimFile  = 'images\win11-pro.wim'
        WimIndex = 1
        Unattend = 'unattend\unattend-win11.xml'
    }
    '3' = @{
        Label    = 'Windows 10 Pro'
        WimFile  = 'images\win10-pro.wim'
        WimIndex = 1          # single-edition export from win10.wim index 6
        Unattend = 'unattend\unattend-win10.xml'
    }
}

# --- Helpers ----------------------------------------------------------------

function Get-NormalizedModelKey([string]$Manufacturer, [string]$Model) {
    $mdl = $Model.Trim()
    $mfr = $Manufacturer.Trim()
    if ($mdl -imatch "^$([regex]::Escape($mfr))\s+") {
        $mdl = $mdl.Substring($mfr.Length).TrimStart()
    }
    $key = "$mfr-$mdl" -replace '[^A-Za-z0-9]', '-' -replace '-{2,}', '-' -replace '^-|-$', ''
    return $key.ToLower()
}

function Get-SmbiosHardwareSerial {
    # WinPE-reliable serial read that does NOT depend on the high-level WMI
    # classes (Win32_BIOS / Win32_SystemEnclosure return junk on Lenovo
    # ThinkPads in WinPE). Reads the raw SMBIOS table via root\wmi
    # MSSmBios_RawSMBiosTables (provided by WinPE-WMI - no Add-Type/csc needed,
    # which matters because WinPE-NetFX ships the runtime but NOT the C#
    # compiler, so Add-Type cannot compile in WinPE) and parses the Type 1
    # (System Information) Serial Number string, with Type 3 (Chassis) as a
    # secondary. Validated on ENG-2 (Lenovo P14s Gen 5): the parsed Type 1
    # serial == (Get-CimInstance Win32_BIOS).SerialNumber exactly.
    # Returns a hashtable @{ Type1=<string>; Type3=<string> }; values $null on
    # any failure. Never throws - wrapped so a missing provider can't break imaging.
    $out = @{ Type1 = $null; Type3 = $null }
    try {
        $raw = (Get-WmiObject -Namespace root\wmi -Class MSSmBios_RawSMBiosTables -ErrorAction Stop).SMBiosData
        if (-not $raw -or $raw.Length -lt 4) { return $out }
        $Data = [byte[]]$raw
        $len = $Data.Length
        $i = 0
        while ($i + 4 -le $len) {
            $type = $Data[$i]
            $flen = $Data[$i + 1]
            if ($flen -lt 4) { break }
            $formattedEnd = $i + $flen
            if ($formattedEnd -gt $len) { break }
            # Walk the null-separated string set after the formatted area
            # (double-null terminates the structure's string table).
            $strings = New-Object System.Collections.Generic.List[string]
            $p = $formattedEnd
            if ($p + 1 -lt $len -and $Data[$p] -eq 0 -and $Data[$p + 1] -eq 0) {
                $p += 2  # no strings present
            } else {
                while ($p -lt $len) {
                    $sb = New-Object System.Text.StringBuilder
                    while ($p -lt $len -and $Data[$p] -ne 0) { [void]$sb.Append([char]$Data[$p]); $p++ }
                    $strings.Add($sb.ToString())
                    $p++  # skip the terminating null
                    if ($p -lt $len -and $Data[$p] -eq 0) { $p++; break }  # double null -> end of structure
                }
            }
            if (($type -eq 1 -or $type -eq 3) -and $flen -ge 8) {
                $idx = $Data[$i + 0x07]   # Serial Number string-index, offset 0x07 in both Type 1 and Type 3
                if ($idx -ge 1 -and $idx -le $strings.Count) {
                    $val = "$($strings[$idx - 1])".Trim()
                    if ($type -eq 1) { $out.Type1 = $val } else { $out.Type3 = $val }
                }
            }
            $i = $p
            if ($type -eq 127) { break }  # end-of-table marker
        }
    } catch {}
    return $out
}

function Get-OemMsdmInfo {
    # Best-effort detection of an embedded OEM Windows digital license by reading
    # the MSDM ACPI firmware table. HONEST WinPE LIMIT: this needs P/Invoke
    # (GetSystemFirmwareTable), which needs Add-Type -> csc.exe. WinPE-NetFX
    # provides only the .NET runtime, not the compiler, so Add-Type generally
    # FAILS in WinPE and this returns Present=$false there. It still works in
    # full Windows (and harmlessly returns nothing if compilation fails), so it
    # is kept as a best-effort signal. There is no root\wmi class that exposes an
    # arbitrary ACPI table by signature, so MSDM cannot be read without P/Invoke.
    # Returns @{ Present=$bool; Key=<25-char key or $null>; CompileOk=$bool }.
    # The product KEY is captured in-memory only and is NEVER logged to the repo
    # or to shared logs.
    $out = @{ Present = $false; Key = $null; CompileOk = $false }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class JuniperFwTable {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint GetSystemFirmwareTable(uint sig, uint id, byte[] buf, uint size);
}
'@ -ErrorAction Stop
        $out.CompileOk = $true
        $acpi = [uint32]0x41435049  # 'ACPI'
        $msdm = [uint32]0x4D44534D  # 'MSDM'
        $sz = [JuniperFwTable]::GetSystemFirmwareTable($acpi, $msdm, $null, 0)
        if ($sz -gt 56) {
            $out.Present = $true
            $buf = New-Object byte[] $sz
            [void][JuniperFwTable]::GetSystemFirmwareTable($acpi, $msdm, $buf, $sz)
            # The 25-char product key (29 bytes incl. 4 dashes) sits at the end of
            # the MSDM table. Extract it but keep it in memory only.
            if ($sz -ge 29) {
                $tail = $buf[($sz - 29)..($sz - 1)]
                $k = (-join ($tail | ForEach-Object { [char]$_ })).Trim()
                if ($k -match '^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$') { $out.Key = $k }
            }
        }
    } catch {}
    return $out
}

function Get-DriverManifest([string]$DeployShare) {
    # Prefer live manifest from inventory API (auto-generated from confirmed_working entries).
    # Falls back to the static manifest.json on the deploy share.
    try {
        $m = Invoke-RestMethod "$InvApi/api/drivers/manifest.json" -TimeoutSec 20 -ErrorAction Stop
        if ($m.models) {
            Write-Host '  (driver manifest: live from inventory API)' -ForegroundColor DarkGray
            return $m
        }
    } catch {}

    $path = "$DeployShare\drivers\manifest.json"
    if (Test-Path $path) {
        return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
    }
    return $null
}

function Invoke-DriverInjection([string]$DeployShare, [string]$Manufacturer, [string]$Model) {
    $manifest = Get-DriverManifest -DeployShare $DeployShare
    if (-not $manifest) {
        Write-Host '  INFO: No driver manifest found - skipping injection.' -ForegroundColor DarkGray
        return
    }
    $normalKey = Get-NormalizedModelKey -Manufacturer $Manufacturer -Model $Model
    $matched   = $null
    foreach ($prop in $manifest.models.PSObject.Properties) {
        if ($prop.Value.wmiModels -contains $Model) { $matched = $prop.Value; break }
    }
    if (-not $matched) {
        foreach ($prop in $manifest.models.PSObject.Properties) {
            if ($prop.Name -eq $normalKey) { $matched = $prop.Value; break }
        }
    }
    if (-not $matched) {
        Write-Host "  WARN: No driver pack for '$Model' (key: $normalKey) - inbox drivers only." -ForegroundColor Yellow
        return
    }
    $driverSrc = "$DeployShare\drivers\$($matched.driverPath)"
    if (-not (Test-Path $driverSrc)) {
        Write-Host "  WARN: Driver pack folder not found: $driverSrc" -ForegroundColor Yellow
        return
    }
    $infCount = (Get-ChildItem $driverSrc -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    Write-Host "  Injecting driver pack for $Model ($infCount .inf files)..." -ForegroundColor Cyan
    $p = Start-Process dism -ArgumentList "/Image:C:\ /Add-Driver /Driver:`"$driverSrc`" /Recurse /ForceUnsigned" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) {
        Write-Host '  Drivers injected successfully.' -ForegroundColor Green
    } else {
        Write-Host "  WARN: DISM driver injection exit $($p.ExitCode) - some drivers may need post-install." -ForegroundColor Yellow
    }
}

function Invoke-UniversalDriverInjection([string]$DeployShare) {
    # ALWAYS-injected drivers, independent of model match. Currently the USB-C
    # Ethernet dongle + Baseus/USB dock NIC drivers (ASIX + Realtek RTL815x), so
    # EVERY imaged machine - especially laptops with NO built-in RJ45 - has a
    # guaranteed wired NIC in the installed OS at first boot. That wired path is
    # what post-OOBE bootstrap uses to reach the inventory server (reset junadmin,
    # pull Wi-Fi creds, install the rest of the drivers). WinPE already has these
    # via inbox drivers; this makes sure the APPLIED OS does too. Best-effort:
    # a missing folder or a DISM warning never blocks imaging.
    $uni = "$DeployShare\drivers\_universal"
    if (-not (Test-Path $uni)) {
        Write-Host '  (no _universal driver folder - skipping universal injection)' -ForegroundColor DarkGray
        return
    }
    $infCount = (Get-ChildItem $uni -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    if ($infCount -eq 0) {
        Write-Host '  (_universal folder has no .inf - skipping)' -ForegroundColor DarkGray
        return
    }
    Write-Host "  Injecting UNIVERSAL drivers (USB-C/dock Ethernet, $infCount .inf)..." -ForegroundColor Cyan
    $p = Start-Process dism -ArgumentList "/Image:C:\ /Add-Driver /Driver:`"$uni`" /Recurse /ForceUnsigned" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) {
        Write-Host '  Universal drivers injected successfully.' -ForegroundColor Green
    } else {
        Write-Host "  WARN: universal DISM injection exit $($p.ExitCode) - dongle may need post-install." -ForegroundColor Yellow
    }
}

function Invoke-DriverCoverageCheck {
    param([string]$DeployShare, [string]$Manufacturer, [string]$Model)

    Write-Host '  -- Driver Coverage Check ----------------------------' -ForegroundColor DarkCyan

    $manifest = Get-DriverManifest -DeployShare $DeployShare
    if (-not $manifest) {
        Write-Host '    No driver manifest - skipping.' -ForegroundColor DarkGray
        return
    }

    # Find driver pack for this model
    $normalKey = Get-NormalizedModelKey -Manufacturer $Manufacturer -Model $Model
    $matched   = $null
    foreach ($p in $manifest.models.PSObject.Properties) {
        if ($p.Value.wmiModels -contains $Model -or $p.Name -eq $normalKey) {
            $matched = $p.Value; break
        }
    }

    if (-not $matched) {
        Write-Host "    No driver pack for '$Model' - inbox drivers only." -ForegroundColor Yellow
        return
    }

    $packPath = "$DeployShare\drivers\$($matched.driverPath)"
    $infFiles = @(Get-ChildItem $packPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)

    if (-not (Test-Path $packPath) -or $infFiles.Count -eq 0) {
        Write-Host "    Pack folder missing or empty: $packPath" -ForegroundColor Yellow
        return
    }

    # Parse every hardware ID from every INF in the pack
    $coveredIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($inf in $infFiles) {
        $raw = $(if (Test-Path $inf.FullName) { [System.IO.File]::ReadAllText($inf.FullName) })
        if (-not $raw) { continue }
        [regex]::Matches($raw, '(?i)(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}|USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') |
            ForEach-Object { $coveredIds.Add($_.Value.ToUpper()) | Out-Null }
    }

    # Enumerate PCI and USB devices on this machine
    $pnp = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareID -and ($_.DeviceID -like 'PCI\*' -or $_.DeviceID -like 'USB\*') })

    # Generic/system names that are always handled by inbox drivers - skip from "not in pack" list
    $genericPatterns = @('PCI Standard','USB Root Hub','USB Composite','USB Hub','Mass Storage',
                         'SCSI','IDE','AHCI','Generic','Thunderbolt Controller','xHCI',
                         'Host Controller','Bridge','PCI Express')

    $inPack    = [System.Collections.Generic.List[string]]::new()
    $notInPack = [System.Collections.Generic.List[string]]::new()

    foreach ($dev in $pnp) {
        $hwid = $dev.HardwareID[0]
        $key  = if     ($hwid -match '(PCI\\VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})') { $matches[1].ToUpper() }
                elseif ($hwid -match '(USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})') { $matches[1].ToUpper() }
                else   { $null }
        if (-not $key) { continue }

        $devName = if ($dev.Name) { $dev.Name } else { $key }

        if ($coveredIds.Contains($key)) {
            $inPack.Add("$devName  [$key]") | Out-Null
        } else {
            $isGeneric = $genericPatterns | Where-Object { $devName -ilike "*$_*" }
            if (-not $isGeneric) {
                $notInPack.Add("$devName  [$key]") | Out-Null
            }
        }
    }

    Write-Host "    Pack     : $($matched.driverPath)  ($($infFiles.Count) INFs, $($coveredIds.Count) HW IDs)" -ForegroundColor Cyan

    if ($inPack.Count -gt 0) {
        Write-Host "    Covered  : $($inPack.Count) device(s)" -ForegroundColor Green
        $inPack | ForEach-Object { Write-Host "      + $_" -ForegroundColor Green }
    }

    if ($notInPack.Count -gt 0) {
        Write-Host "    Not in pack (may use inbox/WU): $($notInPack.Count) device(s)" -ForegroundColor Yellow
        $notInPack | ForEach-Object { Write-Host "      ? $_" -ForegroundColor Yellow }
    } else {
        Write-Host "    Coverage : all PCI/USB devices matched by pack." -ForegroundColor Green
    }
    Write-Host ''
}

# Invoke-FieldCountdown: shows a per-field countdown and waits up to $Seconds.
# Returns $true if the timer elapsed with NO keypress (accept default),
# $false if the operator pressed any key (interrupt -> let them override).
# Modeled on the proven [Console]::KeyAvailable/ReadKey loop in deploy-boot.ps1.
function Invoke-FieldCountdown {
    param(
        [Parameter(Mandatory)][string]$Prompt,   # e.g. "Computer name [JUNIPER-WS-01]"
        [int]$Seconds = 10
    )
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host '  (auto-accept default, or press any key to change)' -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastSec = -1
    $timedOut = $true
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null; $timedOut = $false; break }
        $secsLeft = [int]([math]::Ceiling($Seconds - $sw.Elapsed.TotalSeconds))
        if ($secsLeft -ne $lastSec) {
            $lastSec = $secsLeft
            Write-Host "`r  Auto-accepting in $secsLeft s ... (press any key to change)   " -NoNewline
        }
        Start-Sleep -Milliseconds 100
    }
    $sw.Stop()
    Write-Host ''
    return $timedOut
}

function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host '   Juniper Design  -  PC Deployment System  ' -ForegroundColor Cyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host ''
}

# --- Start ------------------------------------------------------------------

Write-Banner

try { net use $DeployShare /persistent:no *>$null } catch {}
if (-not (Test-Path $DeployShare)) {
    Write-Host "  Cannot reach $DeployShare" -ForegroundColor Red
    Read-Host '  Press Enter to reboot'; wpeutil reboot; exit
}

# --- Collect hardware identity (serial + all physical MACs) -----------------
# Used for inventory preflight lookup and post-imaging MAC registration.

$hwWmiCS   = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
$hwWmiBios = Get-WmiObject -Class Win32_BIOS -ErrorAction SilentlyContinue
$hwMfr     = if ($hwWmiCS)   { $hwWmiCS.Manufacturer.Trim()  } else { 'Unknown' }
$hwModel   = if ($hwWmiCS)   { $hwWmiCS.Model.Trim()         } else { 'Unknown' }
# --- Serial number: multiple UEFI/SMBIOS methods, most-reliable first, each
# strictly validated. The SYSTEM serial (SMBIOS Type 1 == Win32_BIOS on good
# hardware) is what inventory keys on; the baseboard/Type 2 serial is DIFFERENT
# and must NOT be used. MAC is never an identity source here - it is a guarded
# last resort handled below, and only for BUILT-IN NICs (a portable USB ethernet
# dongle carries its MAC between machines and must never establish identity).
$_bogusSer = @('to be filled','default string','system serial','tbd',
               'na','n/a','not specified','none','chassis serial','serial number',
               'oem','o.e.m.','invalid','base board','not available','not applicable',
               '00000000','0000000000','1234567890','0123456789','ffffffff','xxxxxxxx')
function Test-ValidSerial {
    param([string]$s)
    if (-not $s) { return $false }
    $s = $s.Trim()
    if ($s.Length -lt 4 -or $s.Length -gt 64) { return $false }
    if ($s -notmatch '[A-Za-z0-9]')  { return $false }   # must contain alphanumerics
    if ($s -match '^(.)\1+$')        { return $false }   # all one repeated char (000000 / XXXXXX)
    $lc = $s.ToLower()
    foreach ($b in $script:_bogusSer) { if ($lc -like "*$b*") { return $false } }
    return $true
}
# Gather candidate serials from every UEFI source, most-reliable first. In WinPE
# the high-level Win32_* classes return junk on some Lenovo models, so the raw
# SMBIOS Type 1 parse (firmware table via root\wmi, no Add-Type needed) leads.
$_smb = $null; try { $_smb = Get-SmbiosHardwareSerial } catch {}
$_serCand = New-Object System.Collections.Generic.List[object]
if ($_smb -and $_smb.Type1) { $_serCand.Add(@{ src='smbios-type1';    val="$($_smb.Type1)".Trim() }) }
if ($hwWmiBios)             { $_serCand.Add(@{ src='wmi-bios';        val="$($hwWmiBios.SerialNumber)".Trim() }) }
try { $_p = Get-WmiObject Win32_ComputerSystemProduct -ErrorAction SilentlyContinue | Select-Object -First 1; if ($_p) { $_serCand.Add(@{ src='wmi-csproduct'; val="$($_p.IdentifyingNumber)".Trim() }) } } catch {}
try { $_e = Get-WmiObject Win32_SystemEnclosure     -ErrorAction SilentlyContinue | Select-Object -First 1; if ($_e) { $_serCand.Add(@{ src='wmi-enclosure'; val="$($_e.SerialNumber)".Trim() }) } } catch {}
try { $_rb = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue).SystemSerialNumber; if ($_rb) { $_serCand.Add(@{ src='registry-firmware'; val="$_rb".Trim() }) } } catch {}
if ($_smb -and $_smb.Type3) { $_serCand.Add(@{ src='smbios-type3';    val="$($_smb.Type3)".Trim() }) }
$hwSerial = ''; $hwSerialSrc = ''
foreach ($_c in $_serCand) { if (Test-ValidSerial $_c.val) { $hwSerial = $_c.val; $hwSerialSrc = $_c.src; break } }
$serialClean = $hwSerial

# Every physical NIC (Ethernet + Wi-Fi) - collected for inventory association.
# Each NIC is classified built-in vs removable by PNPDeviceID: a USB-attached NIC
# (PNPDeviceID starts with 'USB\') is a portable dongle whose MAC travels between
# machines, so it must NOT be used to establish machine identity. Built-in NICs
# (PCI\... - Wi-Fi/Ethernet) are permanent to the machine and safe to match on.
$allNics = @(
    Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.PhysicalAdapter -eq $true -and $_.MACAddress -ne $null } |
    ForEach-Object {
        $_pnp = "$($_.PNPDeviceID)"
        @{
            mac       = $_.MACAddress.Replace('-',':').ToLower()
            name      = $_.Name
            pnp       = $_pnp
            removable = ($_pnp -like 'USB\*')
            type      = if ($_.Name -imatch 'wi.fi|wifi|802\.11|wlan|wireless') { 'wifi' } else { 'ethernet' }
        }
    }
)
$allMacs      = @($allNics | ForEach-Object { $_['mac'] })                                            # all NICs - for inventory association + registration
$identityMacs = @($allNics | Where-Object { -not $_['removable'] } | ForEach-Object { $_['mac'] })    # BUILT-IN only - for prior-device MATCHING
# Primary/identity MAC (registration + WinPE progress reporting): prefer a BUILT-IN
# wired NIC, then built-in Wi-Fi. NEVER a removable USB dongle unless the machine
# has no built-in NIC at all (e.g. a NIC-less desktop imaging via a USB adapter).
$primaryNic = ($allNics | Where-Object { -not $_['removable'] -and $_['type'] -eq 'ethernet' } | Select-Object -First 1)
if (-not $primaryNic) { $primaryNic = ($allNics | Where-Object { -not $_['removable'] } | Select-Object -First 1) }
if (-not $primaryNic) { $primaryNic = ($allNics | Select-Object -First 1) }
$primaryMac = if ($primaryNic) { $primaryNic['mac'] } else { '' }

# Cache identity for WinPE progress/log reporting to the Imaging tab.
$Script:WpeSerial = if ($serialClean) { $serialClean } else { $null }
$Script:WpeMac    = if ($primaryMac)  { $primaryMac }  else { $null }

# --- UEFI OEM license detection -----------------------------------------------
# OA3xOriginalProductKeyDescription returns e.g. "Windows 11 Home" or "Windows 11 Pro".
# Used to auto-suggest the correct edition for OS selection.
# Fails silently if WinPE does not expose SoftwareLicensingService or the machine
# has no embedded MSDM key (digital license, volume, or VM).
$oemKeyDesc   = ''
$oemOsDefault = ''
$slsEditionResolved = $false   # true only when SLS gave a precise edition name (full Windows)
# WMI can be slow to start in WinPE - retry up to 3 times before giving up.
$slsRetry = 0
do {
    try {
        $slsObj = Get-WmiObject -Namespace root\cimv2 -Class SoftwareLicensingService -ErrorAction Stop
        if ($slsObj.OA3xOriginalProductKey) {
            $rawDesc    = $slsObj.OA3xOriginalProductKeyDescription
            $oemKeyDesc = if ($rawDesc) { $rawDesc } else { '(key present, description unavailable)' }
            $oemOsDefault = switch -Wildcard ($oemKeyDesc) {
                '*11*Home*'         { '1' }
                '*11*Pro*'          { '2' }
                '*11*Professional*' { '2' }
                '*10*'              { '3' }
                default             { '' }
            }
            if ($oemOsDefault) { $slsEditionResolved = $true }
        }
        break  # WMI responded (key may or may not exist)
    } catch {
        $slsRetry++
        if ($slsRetry -lt 3) { Start-Sleep -Seconds 1 }
    }
} while ($slsRetry -lt 3)

# --- Tiered OEM edition default (honest about WinPE limits) -------------------
# The exact edition NAME ("Windows 11 Pro") is only computed by
# SoftwareLicensingService, which does NOT exist in WinPE; and the MSDM ACPI
# table carries the product KEY, not the edition name (key->edition needs
# pkeyconfig, unavailable here). So we cannot read the precise edition in WinPE.
# What we CAN do: detect that an embedded OEM digital license is present and pick
# a sensible default.
#
# $oemMsdm.Present is a best-effort signal - it needs P/Invoke and therefore
# Add-Type/csc, which usually fails in WinPE (NetFX runtime, no compiler), so it
# is typically $false in WinPE and true in full Windows. We never block on it.
$oemMsdm    = Get-OemMsdmInfo
$oemLicensed = $false
if ($oemKeyDesc) {
    # SLS gave us a real description (only happens in full Windows) - most authoritative.
    $oemLicensed = $true
} elseif ($oemMsdm.Present) {
    $oemLicensed = $true
    $oemKeyDesc  = '(OEM digital license present - edition not readable in WinPE)'
}

# Tier (b): for a NEW machine (no SLS edition name, no inventory yet) with an OEM
# license present, default by chassis/model. Juniper images business laptops
# (Lenovo ThinkPad P/T-series, Dell Precision/Latitude) which ship Windows 11 Pro,
# so default to Pro ('2') when an OEM key is present and the model is a business SKU.
# $oemOsDefault is left '' by the SLS block when SLS is unavailable; only fill it
# here if SLS did not already resolve a precise edition.
if (-not $oemOsDefault -and $oemLicensed) {
    $_mfrL = "$hwMfr".ToLower()
    $_mdlL = "$hwModel".ToLower()
    $isBusinessSku =
        ($_mfrL -match 'lenovo' -and $_mdlL -match 'thinkpad|thinkstation|^21|^20') -or
        ($_mfrL -match 'dell'   -and $_mdlL -match 'precision|latitude|optiplex')   -or
        ($_mfrL -match 'hp|hewlett' -and $_mdlL -match 'elitebook|probook|zbook|elitedesk')
    if ($isBusinessSku) {
        $oemOsDefault = '2'  # Windows 11 Pro
    }
}

# --- Detect Hardware --------------------------------------------------------

Write-Host '  -- Hardware Detected ----------------------------------' -ForegroundColor DarkCyan
Write-Host "    Manufacturer : $hwMfr"
Write-Host "    Model        : $hwModel"
Write-Host "    Serial       : $(if ($serialClean) { "$hwSerial  [via $hwSerialSrc]" } else { '(no usable serial - identity will use built-in NIC MAC)' })"
Write-Host "    NICs         : $($allNics.Count) physical ($(@($allNics | Where-Object { -not $_['removable'] }).Count) built-in, $(@($allNics | Where-Object { $_['removable'] }).Count) removable/USB)"
if (@($allNics | Where-Object { $_['removable'] }).Count) { Write-Host "                   removable (NOT used for identity): $((@($allNics | Where-Object { $_['removable'] } | ForEach-Object { $_['mac'] }) -join ', '))" -ForegroundColor DarkGray }
if ($oemKeyDesc) {
    $oemHint = if ($oemOsDefault) { "  -> defaulting to [$oemOsDefault] $($OsOptions[$oemOsDefault].Label)" } else { '' }
    Write-Host "    UEFI License : $oemKeyDesc$oemHint" -ForegroundColor Green
    if ($oemLicensed -and $oemOsDefault -and -not $slsEditionResolved) {
        Write-Host "                   OEM digital license detected (defaulting to $($OsOptions[$oemOsDefault].Label) for business SKU)" -ForegroundColor DarkGray
    }
} else {
    Write-Host '    UEFI License : (no OEM key detected in WinPE - select edition manually)' -ForegroundColor DarkGray
}

Write-Host ''

Invoke-DriverCoverageCheck -DeployShare $DeployShare -Manufacturer $hwMfr -Model $hwModel

# --- Inventory preflight lookup ---------------------------------------------
# Look up this machine by serial number to pre-populate defaults.
# Fails silently - deployment always continues if the API is unreachable.

# Resolution order matches the inventory server's own dedupe priority:
#   1. BIOS/chassis serial (most stable)   2. primary MAC (Ethernet preferred)
# Only EXACT matches are accepted - a fuzzy serial/MAC could pick the wrong machine.
$prior     = $null
$priorVia  = ''   # 'serial' or 'mac' - for logging only

function Resolve-PriorDevice {
    param([string]$Query, [string]$ExactField, [string]$ExactValue)
    # Returns the device record whose $ExactField equals $ExactValue (case-insensitive), or $null.
    try {
        $results = Invoke-RestMethod "$InvApi/api/devices?q=$([uri]::EscapeDataString($Query))" `
            -TimeoutSec 20 -ErrorAction Stop
        return @($results | Where-Object { "$($_.$ExactField)" -ieq $ExactValue }) | Select-Object -First 1
    } catch { return $null }
}

$match = $null
if ($serialClean) {
    $match = Resolve-PriorDevice -Query $hwSerial -ExactField 'serial_number' -ExactValue $hwSerial
    if ($match) { $priorVia = "serial ($hwSerialSrc)" }
}
if (-not $match) {
    # Serial did not resolve. Fall back to MAC - but ONLY built-in NIC MACs. A
    # portable USB ethernet dongle carries its MAC between machines and would
    # misidentify this box as whatever machine last used the dongle (the reason a
    # dongle last used on JB-THINKPAD made a different laptop resolve to it). The
    # built-in Wi-Fi/Ethernet MAC is permanent to this machine, so it is safe.
    foreach ($m in $identityMacs) {
        if (-not $m) { continue }
        $match = Resolve-PriorDevice -Query $m -ExactField 'mac_address' -ExactValue $m
        if ($match) { $priorVia = 'mac (built-in NIC)'; break }
    }
    if (-not $match -and $identityMacs.Count -eq 0 -and $primaryMac) {
        # No built-in NIC exists at all (e.g. a desktop imaging via a USB NIC).
        # Only then, as an absolute last resort, match on the removable adapter -
        # flagged low-confidence so a wrong name/OS pre-fill is obvious to the tech.
        $match = Resolve-PriorDevice -Query $primaryMac -ExactField 'mac_address' -ExactValue $primaryMac
        if ($match) { $priorVia = 'mac (removable adapter - LOW CONFIDENCE)' }
    }
}
if ($match) {
    # Prefer os_caption (the canonical OS string written at image time) then os.
    $invOs = if ($match.os_caption) { $match.os_caption } else { $match.os }
    # Map inventory OS string to local os_key ('1'=Win11Home, '2'=Win11Pro, '3'=Win10Pro)
    $osKeyFromInv = switch -Wildcard ($invOs) {
        '*11*Home*'  { '1' }
        '*11*Pro*'   { '2' }
        '*10*'       { '3' }
        default      { '' }    # unknown - let UEFI or operator decide
    }
    # oem_edition is the AUTHORITATIVE UEFI/MSDM licensed edition - the agent read it
    # in the full OS (where SLS works; WinPE cannot) and stored it. This is the
    # "never guess" source: it says what edition this machine is LICENSED for,
    # regardless of what was last installed.
    $oemKeyFromInv = switch -Wildcard ("$($match.oem_edition)") {
        '*Pro*'   { '2' }
        '*Home*'  { '1' }
        default   { '' }
    }
    $prior = [PSCustomObject]@{
        device_id = $match.id
        hostname  = $match.hostname
        os        = $invOs
        os_key    = $osKeyFromInv
        oem_key   = $oemKeyFromInv
        oem_edition = $match.oem_edition
        last_seen = $match.last_seen
    }
}

# --- OS + Computer Name selection -------------------------------------------
# Two INDEPENDENT fields, each with its own 10-second pre-fill countdown:
#   Name field: default = last inventory hostname.  OS field: default =
#   UEFI license edition (preferred) else last inventory OS.
# If the operator presses any key within 10 s the countdown stops and they
# override that ONE field (the other field's countdown is unaffected).
# Timeout with no keypress accepts the default.  No default -> today's prompt.

$osKey        = ''
$computerName = ''

# Defaults from inventory / UEFI
$defaultName  = if ($prior -and $prior.hostname) { "$($prior.hostname)".ToUpper() } else { '' }
# Edition default precedence (tiered, documented in CLAUDE.md):
#   (a) A PRECISE SLS edition name ($slsEditionResolved, full Windows only) is the
#       most authoritative - it wins over everything.
#   (b) Inventory's last os_key (now reliable after the API fix) wins for re-images
#       over a mere business-SKU *guess* - a known machine keeps its recorded edition.
#   (c) Otherwise the business-SKU OEM default ($oemOsDefault set to Pro when an MSDM
#       license is present on a business laptop) applies for brand-new hardware.
#   (d) Else no default -> operator menu.
$defaultOsKey =
    if     ($prior -and $prior.oem_key)          { $prior.oem_key }     # (a) AUTHORITATIVE UEFI/MSDM license (agent read it in full OS) - never a guess
    elseif ($slsEditionResolved -and $oemOsDefault) { $oemOsDefault }   # (b) live SLS edition (full-Windows deploy only)
    elseif ($prior -and $prior.os_key)          { $prior.os_key }       # (c) last-installed edition from inventory
    elseif ($oemOsDefault)                       { $oemOsDefault }       # (d) business-SKU OEM guess
    else { '' }                                                          # (e) operator menu

# Show what was found
if ($prior) {
    Write-Host '  -- Inventory match found --------------------------------' -ForegroundColor Green
    Write-Host "    Resolved via: $priorVia" -ForegroundColor DarkGray
    Write-Host "    Name:      $($prior.hostname)" -ForegroundColor Green
    Write-Host "    Last OS:   $($prior.os)" -ForegroundColor DarkGray
    if ($prior.last_seen) { Write-Host "    Last seen: $($prior.last_seen)" -ForegroundColor DarkGray }
    if ($oemOsDefault -and $prior.os_key -and $oemOsDefault -ne $prior.os_key) {
        Write-Host "    (UEFI license: $($OsOptions[$oemOsDefault].Label) overrides inventory OS: $($prior.os))" -ForegroundColor Yellow
    }
    Write-Host ''
}

# Helper: validate a candidate computer name (1-15 chars, A-Z0-9 and hyphen, no edge hyphen)
function Test-ComputerName([string]$n) {
    return ($n -match '^[A-Z0-9]([A-Z0-9\-]{0,13}[A-Z0-9])?$' -and $n.Length -ge 1 -and $n.Length -le 15)
}

# === Field 1: Computer name =================================================
if ($defaultName) {
    $accept = Invoke-FieldCountdown -Prompt "Computer name [$defaultName]" -Seconds 10
    if ($accept) {
        $computerName = $defaultName
        Write-Host "  Name: $computerName (default accepted)" -ForegroundColor Green
    } else {
        # Operator wants to override - prompt, default applied on empty input
        Write-Host '  New name (Enter to keep default), 1-15 chars letters/numbers/hyphens:' -ForegroundColor Cyan
        while ($true) {
            $entry = (Read-Host "  Name [$defaultName]").Trim().ToUpper()
            if (-not $entry) { $computerName = $defaultName; break }
            if (Test-ComputerName $entry) { $computerName = $entry; break }
            Write-Host '    Invalid. Letters/numbers/hyphens, max 15 chars.' -ForegroundColor Yellow
        }
        Write-Host "  Name: $computerName" -ForegroundColor Green
    }
} else {
    # No default - today's mandatory prompt
    Write-Host ''
    Write-Host '  Computer name: (1-15 chars, letters/numbers/hyphens e.g. JUNIPER-WS-01)' -ForegroundColor Cyan
    while ($true) {
        $entry = (Read-Host '  Name').Trim().ToUpper()
        if (Test-ComputerName $entry) { $computerName = $entry; break }
        Write-Host '    Invalid. Letters/numbers/hyphens, max 15 chars.' -ForegroundColor Yellow
    }
}

# === Field 2: OS / edition ==================================================
if ($defaultOsKey) {
    $src = if ($prior -and $prior.oem_key -eq $defaultOsKey -and $prior.oem_key) { 'UEFI license (OEM)' }
           elseif ($oemOsDefault -eq $defaultOsKey) { 'UEFI license' } else { 'inventory' }
    $accept = Invoke-FieldCountdown -Prompt "OS edition [$($OsOptions[$defaultOsKey].Label)]  (from $src)" -Seconds 10
    if ($accept) {
        $osKey = $defaultOsKey
        Write-Host "  OS: $($OsOptions[$osKey].Label) (default accepted)" -ForegroundColor Green
    } else {
        Write-Host '  Select OS to deploy:' -ForegroundColor Cyan
        foreach ($k in ($OsOptions.Keys | Sort-Object)) {
            $hint = if ($k -eq $oemOsDefault) { '  <- UEFI key' } elseif ($k -eq $defaultOsKey) { '  <- last imaged' } else { '' }
            Write-Host "    [$k] $($OsOptions[$k].Label)$hint"
        }
        Write-Host "  (Enter to keep default [$defaultOsKey] $($OsOptions[$defaultOsKey].Label))" -ForegroundColor DarkGray
        while ($true) {
            $choice = (Read-Host '  Choice').Trim()
            if (-not $choice) { $osKey = $defaultOsKey; break }
            if ($choice -in $OsOptions.Keys) { $osKey = $choice; break }
        }
        Write-Host "  OS: $($OsOptions[$osKey].Label)" -ForegroundColor Green
    }
} else {
    # No default - today's manual menu
    Write-Host ''
    Write-Host '  Select OS to deploy:' -ForegroundColor Cyan
    foreach ($k in ($OsOptions.Keys | Sort-Object)) {
        $uefiHint = if ($k -eq $oemOsDefault) { '  <- UEFI key' } else { '' }
        Write-Host "    [$k] $($OsOptions[$k].Label)$uefiHint"
    }
    Write-Host ''
    while ($osKey -notin $OsOptions.Keys) { $osKey = (Read-Host '  Choice').Trim() }
}

$os = $OsOptions[$osKey]
$wimPath = Join-Path $DeployShare $os.WimFile
if (-not (Test-Path $wimPath)) {
    Write-Host "  WIM not found: $wimPath" -ForegroundColor Red
    Write-Host "  Export with: dism /Export-Image /SourceImageFile:<iso-install.wim> /SourceIndex:<n> /DestinationImageFile:C:\deploy\images\$($os.WimFile | Split-Path -Leaf) /Compress:fast" -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'; wpeutil reboot; exit
}

# Name is now known - set for Write-DeployLog remote log key
$Script:WpeTargetName = $computerName

# First WinPE milestone -> Imaging tab (same device_provisioning record the
# post-install orchestrator will later continue through to 'done').
Send-WinpeProgress -Percent 1 -Label 'Imaging Windows' -Step 'Starting imaging'

# First event on the append-only timeline. -Reset clears this device's prior
# events so each fresh image starts a clean history. Machine/name/OS are already
# resolved above (inventory match + operator choices).
Publish-Event -PhaseKey 'winpe' -Step 'start' -Status 'running' -Message "Imaging $computerName ($($os.Label))" -Percent 1 -Reset
Publish-Event -PhaseKey 'winpe' -Step 'resolve-machine' -Status 'ok' -Message "$hwMfr $hwModel | serial $(if ($serialClean) { $hwSerial } else { '(none)' }) | $(if ($prior) { "inventory match via $priorVia" } else { 'new machine' })"

# Send first remote log entry immediately so the machine appears on pc-deploy
try {
    $ts0     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $uefiLog = if ($oemKeyDesc) { "UEFI: $oemKeyDesc" } else { 'UEFI: no OEM key detected (WMI+MSDM both failed)' }
    $body0 = [ordered]@{
        computer_name = $computerName
        lines = @(
            "$ts0  [INFO ]  [winpe                 ]  === Juniper Imaging Start ===",
            "$ts0  [INFO ]  [winpe                 ]  Machine: $computerName | OS: $($OsOptions[$osKey].Label)",
            "$ts0  [INFO ]  [winpe                 ]  Mfr: $hwMfr | Model: $hwModel | Serial: $hwSerial",
            "$ts0  [INFO ]  [winpe                 ]  $uefiLog"
        )
    } | ConvertTo-Json -Compress
    Invoke-RestMethod "$InvApi/ingest/imaging-log" -Method POST -Body $body0 `
        -ContentType 'application/json' -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
} catch {}

# --- Disk 0 Info + Confirmation ---------------------------------------------

Write-Host ''
Write-Host '  -- Target: Disk 0 ------------------------------------' -ForegroundColor Cyan
$disk = Get-Disk | Where-Object Number -eq 0 | Select-Object -First 1
if ($disk) {
    Write-Host "    Model : $($disk.FriendlyName)"
    Write-Host "    Size  : $([math]::Round($disk.Size/1GB, 0)) GB"
    Write-Host "    Style : $($disk.PartitionStyle)"
}
Write-Host ''
Write-Host "    OS    : $($os.Label)"
Write-Host "    Name  : $computerName"
Write-Host ''
Write-Host '  !! Disk 0 will be COMPLETELY WIPED !!' -ForegroundColor Red

# --- Partition Disk 0 (GPT / UEFI) -----------------------------------------

Write-DeployLog 'Step: Partitioning disk 0 (GPT/UEFI)'
Publish-Event -PhaseKey 'winpe' -Step 'partition-disk' -Status 'running' -Message 'Partitioning disk 0 (GPT/UEFI)' -Percent 2
Write-Host ''
Write-Host '  Partitioning disk 0 (GPT/UEFI)...' -ForegroundColor Cyan
$dpTxt = @'
select disk 0
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
exit
'@
$dpFile = "$env:TEMP\juniper_diskpart.txt"
$dpTxt | Set-Content $dpFile -Encoding ASCII
$p = Start-Process diskpart -ArgumentList "/s `"$dpFile`"" -Wait -PassThru -NoNewWindow
Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) {
    Write-Host "  diskpart failed (exit $($p.ExitCode))" -ForegroundColor Red
    Publish-Event -PhaseKey 'winpe' -Step 'partition-disk' -Status 'error' -Message "diskpart failed (exit $($p.ExitCode))" -Percent 2
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Partitioned: S: (EFI), C: (Windows).' -ForegroundColor Green
Write-DeployLog 'Step: Partition complete'
Publish-Event -PhaseKey 'winpe' -Step 'partition-disk' -Status 'ok' -Message 'Disk partitioned: S: (EFI), C: (Windows)' -Percent 2
Send-WinpeProgress -Percent 2 -Label 'Imaging Windows' -Step 'Disk partitioned'

# --- Apply WIM --------------------------------------------------------------

Write-DeployLog "Step: Applying $($os.Label) (DISM - 10-20 min)"
Send-WinpeProgress -Percent 3 -Label 'Applying Windows image' -Step "Applying $($os.Label)"
Publish-Event -PhaseKey 'winpe' -Step 'apply-wim' -Status 'running' -Message "Applying $($os.Label) (DISM, 10-20 min)" -Percent 3
Write-Host ''
Write-Host "  Applying $($os.Label) (index $($os.WimIndex))..." -ForegroundColor Cyan
Write-Host '  This takes 10-20 minutes depending on disk speed.'
Write-Host ''
$p = Start-Process dism -ArgumentList "/Apply-Image /ImageFile:`"$wimPath`" /Index:$($os.WimIndex) /ApplyDir:C:\" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  DISM apply failed (exit $($p.ExitCode))" -ForegroundColor Red
    Send-WinpeProgress -Percent 3 -Label 'Applying Windows image' -Step "DISM apply failed (exit $($p.ExitCode))" -State 'error'
    Publish-Event -PhaseKey 'winpe' -Step 'apply-wim' -Status 'error' -Message "DISM apply failed (exit $($p.ExitCode))" -Percent 3
    Send-WinpeLog -Status 'error'
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Image applied.' -ForegroundColor Green
Write-DeployLog 'Step: WIM applied'
Publish-Event -PhaseKey 'winpe' -Step 'apply-wim' -Status 'ok' -Message "$($os.Label) image applied" -Percent 4
Send-WinpeProgress -Percent 4 -Label 'Injecting drivers' -Step 'Windows image applied'

# --- Inject Drivers (offline) -----------------------------------------------

Write-DeployLog "Step: Injecting drivers for $hwModel"
Publish-Event -PhaseKey 'winpe' -Step 'inject-drivers' -Status 'running' -Message "Injecting drivers for $hwModel" -Percent 4
Write-Host ''
Write-Host '  Injecting hardware drivers...' -ForegroundColor Cyan
Invoke-DriverInjection -DeployShare $DeployShare -Manufacturer $hwMfr -Model $hwModel
# Always inject the USB-C / dock Ethernet drivers so a laptop with no built-in
# RJ45 still comes up wired at first boot (post-OOBE bootstrap needs a NIC).
Invoke-UniversalDriverInjection -DeployShare $DeployShare
# ALSO stage the _universal tree onto the target OS so the first-boot
# install-network-drivers phase can ACTIVELY install them (pnputil /add-driver
# /install). Offline injection alone does not auto-bind a Class_FF USB NIC that is
# present at first boot (e.g. Lenovo ThinkPad USB-C Ethernet) - it must be actively
# installed. This local copy needs no network at first boot.
try {
    $uniSrc = "$DeployShare\drivers\_universal"
    $uniDst = 'C:\ProgramData\JuniperSetup\universal-drivers'
    if (Test-Path $uniSrc) {
        New-Item $uniDst -ItemType Directory -Force | Out-Null
        Copy-Item "$uniSrc\*" $uniDst -Recurse -Force -ErrorAction SilentlyContinue
        $n = (Get-ChildItem $uniDst -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
        Write-Host "  Staged $n universal USB-Ethernet .inf to target for first-boot active install." -ForegroundColor Green
    }
} catch { Write-Host "  WARN: staging universal drivers to target failed: $_" -ForegroundColor Yellow }
Publish-Event -PhaseKey 'winpe' -Step 'inject-drivers' -Status 'ok' -Message "Driver injection complete for $hwModel (+ universal USB Ethernet)" -Percent 4

# --- Inject unattend.xml with computer name ---------------------------------

Write-DeployLog 'Step: Writing unattend.xml'
Write-Host ''
Write-Host '  Writing unattend.xml...' -ForegroundColor Cyan
$unattendSrc = Join-Path $DeployShare $os.Unattend
if (-not (Test-Path $unattendSrc)) {
    Write-Host "  WARN: Unattend not found at $unattendSrc - skipping." -ForegroundColor Yellow
    Publish-Event -PhaseKey 'winpe' -Step 'inject-unattend' -Status 'warning' -Message "Unattend not found at $unattendSrc - skipped" -Percent 4
} else {
    New-Item 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null
    $xml = ([System.IO.File]::ReadAllText($unattendSrc)) -replace '<ComputerName>\*</ComputerName>', "<ComputerName>$computerName</ComputerName>"
    $xml | Set-Content 'C:\Windows\Panther\unattend.xml' -Encoding UTF8
    Write-Host "  unattend.xml written (ComputerName=$computerName)." -ForegroundColor Green
    Publish-Event -PhaseKey 'winpe' -Step 'inject-unattend' -Status 'ok' -Message "unattend.xml written (ComputerName=$computerName)" -Percent 4
}

# --- Stage post-install automation ------------------------------------------
# Copies SetupComplete.cmd and all orchestration/phase scripts to the target.
# SetupComplete.cmd fires once post-OOBE as SYSTEM (before login screen),
# creates the JuniperImaging scheduled task, and kicks off the phase pipeline.
# The task runs on every startup until all phases complete - no login needed.

Write-DeployLog 'Step: Staging post-install scripts'
Write-Host ''
Write-Host '  Staging post-install automation...' -ForegroundColor Cyan

$jsRoot    = 'C:\ProgramData\JuniperSetup'
$jsScripts = "$jsRoot\scripts"
$jsLogs    = "$jsRoot\logs"
foreach ($dir in @('C:\Windows\Setup\Scripts', $jsRoot, $jsScripts, $jsLogs)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# SetupComplete.cmd -> fires once post-OOBE, bootstraps the scheduled task
Copy-Item "$DeployShare\scripts\SetupComplete.cmd" 'C:\Windows\Setup\Scripts\SetupComplete.cmd' -Force

# Orchestration core (root of JuniperSetup, sourced by phase scripts).
# provision-status.ps1 is the fullscreen lockout/status GUI; it lives at the root
# because the junadmin kiosk Winlogon Shell points directly at this path.
foreach ($f in @('Logging.ps1', 'progress.ps1', 'orchestrator.ps1', 'provision-status.ps1')) {
    $src = "$DeployShare\scripts\$f"
    if (Test-Path $src) { Copy-Item $src "$jsRoot\$f" -Force }
}

# Phase scripts (+ provision-status copy in scripts dir so it self-updates too).
# Stage EVERY phase in $Phases so a phase is never skipped as "script missing" on
# the first boot (the orchestrator's Sync-Scripts backfills from the share too, but
# staging them all here removes any timing dependency - this is how 10-setup-user
# got skipped before).
foreach ($f in @('03-windows-update.ps1','04-install-packages.ps1',
                 '05-install-network-drivers.ps1','06-join-wifi.ps1',
                 '07-remove-bloatware.ps1','08-set-file-associations.ps1','10-setup-user.ps1',
                 'provision-status.ps1')) {
    $src = "$DeployShare\scripts\$f"
    if (Test-Path $src) { Copy-Item $src "$jsScripts\$f" -Force }
}

Write-Host '  Post-install automation staged (SetupComplete + orchestrator + status GUI + 7 phase scripts).' -ForegroundColor Green

# --- Stage bootstrap creds LOCALLY (dongle-independent first boot) -------------
# We are in WinPE right now, where the USB-C dongle works reliably (it is how this
# machine is imaging). Fetch the junadmin password + Wi-Fi creds NOW and write them
# to an ACL'd local file on the target. First-boot bootstrap then reads this file
# with NO network - it resets junadmin off CHANGEME, arms the kiosk, and joins the
# stable built-in Wi-Fi - instead of waiting on the flaky dongle to re-enumerate in
# the full OS. Secrets live ONLY in this SYSTEM/Administrators-ACL'd file (deleted at
# provisioning teardown), never in the repo or any log. Best-effort: on failure,
# bootstrap falls back to the (network-dependent) API.
try {
    $bootCredPath = "$jsRoot\boot-creds.json"
    $bs = $null; $wf = $null
    try { $bs = Invoke-RestMethod "$InvApi/api/management/bootstrap" -TimeoutSec 10 -ErrorAction Stop } catch {}
    try { $wf = Invoke-RestMethod "$InvApi/api/management/wifi"      -TimeoutSec 10 -ErrorAction Stop } catch {}
    if ($bs.password -or $wf.ssid) {
        ([ordered]@{ junadminPassword = $bs.password; wifiSsid = $wf.ssid; wifiPsk = $wf.psk } |
            ConvertTo-Json) | Set-Content $bootCredPath -Encoding UTF8
        & icacls $bootCredPath /inheritance:r /grant:r 'SYSTEM:F' 'Administrators:F' 2>&1 | Out-Null
        $bs = $null; $wf = $null
        Write-Host '  Staged local boot creds (junadmin + Wi-Fi) for dongle-independent bootstrap.' -ForegroundColor Green
        Write-DeployLog 'Staged local boot-creds.json (junadmin + Wi-Fi) - first boot no longer needs the dongle'
    } else {
        Write-Host '  WARN: could not fetch junadmin/Wi-Fi creds in WinPE - bootstrap will fall back to API.' -ForegroundColor Yellow
    }
} catch { Write-Host "  WARN: staging local boot creds failed (non-fatal): $_" -ForegroundColor Yellow }

# Set staging log paths so Write-DeployLog can write to them
$Script:WpeMasterLog = "$jsRoot\imaging.log"
$Script:WpePhaseLog  = "$jsLogs\winpe.log"

# Write imaging-start log (local on target + remote on pc-deploy)
Write-DeployLog "=== Juniper Imaging Start ==="
Write-DeployLog "Machine: $computerName | OS: $($os.Label)"
Write-DeployLog "Mfr: $hwMfr | Model: $hwModel | Serial: $hwSerial"

# --- Pre-register in inventory ----------------------------------------------
# Uses the inventory agent directly - same data gathering as post-install.
# $JUNIPER_HOSTNAME_OVERRIDE passes the target computer name since WinPE
# reports 'MINWINPC' for $env:COMPUTERNAME.

Write-DeployLog 'Step: Registering in inventory'
Publish-Event -PhaseKey 'winpe' -Step 'inventory-preregister' -Status 'running' -Message "Pre-registering $computerName in inventory" -Percent 4
Write-Host ''
Write-Host '  Registering in inventory...' -ForegroundColor DarkGray
$invDeviceId = if ($prior) { $prior.device_id } else { $null }
try {
    $JUNIPER_HOSTNAME_OVERRIDE = $computerName
    Invoke-Expression (Invoke-RestMethod "$InvApi/static/install_agent.ps1" -TimeoutSec 10)
    # Look up device_id by serial so we can PATCH the OS/notes below
    if (-not $invDeviceId) {
        $lookup = Invoke-RestMethod "$InvApi/api/devices?q=$hwSerial" -TimeoutSec 5 -ErrorAction SilentlyContinue
        $invDeviceId = if ($lookup.Count -gt 0) { $lookup[0].device_id } else { $null }
    }
    # Update OS in inventory using the selected edition (ingest/endpoint is always available,
    # unlike the PATCH route which requires auth). This ensures the next re-image defaults correctly.
    # Must use bios_serial/chassis_serial (not serial_number) - that is what find_or_create_device reads.
    # Include MACs so find_or_create_device uses MAC identity rather than just serial+hostname,
    # which avoids creating ghost records when serial is not yet in the DB.
    # NOTE: use $OsOptions[$osKey].Label, NOT $os.Label - the install_agent.ps1 run
    # via Invoke-Expression above assigns its own `$os = Get-WmiObject
    # Win32_OperatingSystem`, which clobbers our $os (the edition object) in this
    # shared scope. $os.Label would then be blank -> we stored "Microsoft " with no
    # edition, so re-image "default to last selection" had nothing to map. $osKey is
    # untouched by the agent, so it is the safe source of the selected edition label.
    $osCaption     = "Microsoft $($OsOptions[$osKey].Label)"
    $ethernetMacs  = @($allNics | Where-Object { $_['type'] -eq 'ethernet' } | ForEach-Object { $_['mac'] })
    $wirelessMacs  = @($allNics | Where-Object { $_['type'] -eq 'wifi'     } | ForEach-Object { $_['mac'] })
    $osPatch   = @{
        bios_serial    = $hwSerial
        chassis_serial = $hwSerial
        hostname       = $computerName
        os_caption     = $osCaption
        ethernet_macs  = $ethernetMacs
        wireless_macs  = $wirelessMacs
    } | ConvertTo-Json -Compress
    Invoke-RestMethod "$InvApi/ingest/endpoint" -Method Post -Body $osPatch `
        -ContentType 'application/json' -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    Publish-Event -PhaseKey 'winpe' -Step 'inventory-preregister' -Status 'ok' -Message "$computerName pre-registered ($osCaption)" -Percent 4
} catch {
    Write-Host '  Inventory registration skipped (server unreachable - will register post-install).' -ForegroundColor DarkGray
    Publish-Event -PhaseKey 'winpe' -Step 'inventory-preregister' -Status 'warning' -Message "Inventory registration skipped (server unreachable): $($_.Exception.Message)" -Percent 4
}

# --- Boot sector ------------------------------------------------------------

Write-DeployLog 'Step: Configuring UEFI boot'
Publish-Event -PhaseKey 'winpe' -Step 'bcdboot' -Status 'running' -Message 'Configuring UEFI boot sector (bcdboot)' -Percent 5
Write-Host ''
Write-Host '  Configuring UEFI boot...' -ForegroundColor Cyan
$p = Start-Process bcdboot -ArgumentList 'C:\Windows /s S: /f UEFI' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  bcdboot failed (exit $($p.ExitCode))" -ForegroundColor Red
    Publish-Event -PhaseKey 'winpe' -Step 'bcdboot' -Status 'error' -Message "bcdboot failed (exit $($p.ExitCode))" -Percent 5
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Boot sector configured.' -ForegroundColor Green
Publish-Event -PhaseKey 'winpe' -Step 'bcdboot' -Status 'ok' -Message 'UEFI boot sector configured' -Percent 5

# --- UEFI boot order: Windows first, PXE removed ----------------------------

Write-Host ''
Write-Host '  Setting UEFI boot order...' -ForegroundColor Cyan

# Move Windows Boot Manager to top of EFI boot order
$p = Start-Process bcdedit -ArgumentList '/set "{fwbootmgr}" displayorder "{bootmgr}" /addfirst' `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput "$env:TEMP\bcd1_o.txt" `
    -RedirectStandardError  "$env:TEMP\bcd1_e.txt"
if ($p.ExitCode -eq 0) {
    Write-Host '  Windows Boot Manager: first in EFI order.' -ForegroundColor Green
} else {
    $bcdErr = (Get-Content "$env:TEMP\bcd1_e.txt" -ErrorAction SilentlyContinue) -join ' '
    Write-Host "  WARN: Boot order update failed (exit $($p.ExitCode)): $bcdErr" -ForegroundColor Yellow
}

# Enumerate firmware entries and remove PXE / EFI Network boot options
$fwOut = "$env:TEMP\bcd_fw.txt"
Start-Process bcdedit -ArgumentList '/enum firmware' -Wait -NoNewWindow `
    -RedirectStandardOutput $fwOut `
    -RedirectStandardError  "$env:TEMP\bcd_fwe.txt" | Out-Null
$fwLines    = Get-Content $fwOut -ErrorAction SilentlyContinue
$pxeGuid    = $null
$pxeRemoved = 0
foreach ($fwLine in $fwLines) {
    if ($fwLine -match '^\s+identifier\s+(\{[0-9a-fA-F\-]+\})') {
        $pxeGuid = $Matches[1]
    }
    if ($pxeGuid -and
        $pxeGuid -notin @('{bootmgr}','{fwbootmgr}') -and
        $fwLine  -match 'description\s+.*(PXE|EFI Network|IPv4|IPv6|Network Boot)') {
        $pdel = Start-Process bcdedit -ArgumentList "/delete `"$pxeGuid`"" `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\bcd_del_o.txt" `
            -RedirectStandardError  "$env:TEMP\bcd_del_e.txt"
        if ($pdel.ExitCode -eq 0) {
            Write-Host "  Removed PXE entry: $pxeGuid" -ForegroundColor DarkGray
            $pxeRemoved++
        } else {
            Write-Host "  PXE entry deprioritized (firmware-protected): $pxeGuid" -ForegroundColor DarkGray
        }
        $pxeGuid = $null
    }
    if ($fwLine -match '^\s*$') { $pxeGuid = $null }
}
if ($pxeRemoved -gt 0) {
    Write-Host "  PXE: $pxeRemoved boot entr$(if ($pxeRemoved -eq 1){'y'}else{'ies'}) removed." -ForegroundColor Green
} else {
    Write-Host '  PXE: no deletable entries found (will be lower priority than Windows).' -ForegroundColor DarkGray
}

# --- Write final WinPE log entry before disconnecting share -----------------

Write-DeployLog "WinPE phase complete - rebooting into Windows"
# Final WinPE milestone + upload of the WinPE log to the Imaging tab. The
# post-install orchestrator takes over this same device record after first boot.
Send-WinpeProgress -Percent 5 -Label 'Finalizing - rebooting to Windows' -Step 'Rebooting into Windows setup'
Publish-Event -PhaseKey 'winpe' -Step 'reboot' -Status 'ok' -Message 'WinPE phase complete - rebooting into Windows setup' -Percent 5
Send-WinpeLog -Status 'ok'

# --- Cleanup and reboot -----------------------------------------------------

try { net use $DeployShare /delete *>$null } catch {}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Green
Write-Host "   Done: $($OsOptions[$osKey].Label) -> $computerName" -ForegroundColor Green
Write-Host '   Rebooting in 15 seconds...               ' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''
Start-Sleep 15
wpeutil reboot
