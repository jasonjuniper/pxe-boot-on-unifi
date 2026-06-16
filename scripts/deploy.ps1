# deploy.ps1 - Juniper Design WinPE Deployment Script
#
# Lives on the DEPLOY SHARE at \\192.168.5.141\deploy$\scripts\deploy.ps1
# Launched by deploy-boot.ps1 (baked into WinPE) after the share is mapped.
#
# To update without rebuilding WinPE: edit this file and copy to pc-deploy:
#   scripts\deploy.ps1 -> C:\deploy\scripts\deploy.ps1 on pc-deploy
#
# AUTOMATION: deploy.ps1 queries the inventory API by serial number.
# If the machine is recognised, its prior hostname and OS are used as
# defaults with a 30-second countdown.  The operator can press any key
# to override.  Unknown machines always prompt.
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

function Get-DriverManifest([string]$DeployShare) {
    # Prefer live manifest from inventory API (auto-generated from confirmed_working entries).
    # Falls back to the static manifest.json on the deploy share.
    try {
        $m = Invoke-RestMethod "$InvApi/api/drivers/manifest.json" -TimeoutSec 5 -ErrorAction Stop
        if ($m.models) {
            Write-Host '  (driver manifest: live from inventory API)' -ForegroundColor DarkGray
            return $m
        }
    } catch {}

    $path = "$DeployShare\drivers\manifest.json"
    if (Test-Path $path) {
        return (Get-Content $path -Raw | ConvertFrom-Json)
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
        $raw = Get-Content $inf.FullName -Raw -ErrorAction SilentlyContinue
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
$hwSerial  = if ($hwWmiBios) { $hwWmiBios.SerialNumber.Trim() } else { '' }

# Filter placeholder serials that BIOSes ship with
$_bogus = @('to be filled','default string','system serial','tbd','0','00000000',
            'na','n/a','not specified','none','chassis serial','ffffffffff')
$serialClean = $hwSerial
foreach ($b in $_bogus) { if ($serialClean -ilike "*$b*") { $serialClean = ''; break } }

# Every physical NIC (Ethernet + Wi-Fi) - collected for inventory association
$allNics = @(
    Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.PhysicalAdapter -eq $true -and $_.MACAddress -ne $null } |
    ForEach-Object {
        @{
            mac  = $_.MACAddress.Replace('-',':').ToLower()
            name = $_.Name
            type = if ($_.Name -imatch 'wi.fi|wifi|802\.11|wlan|wireless') { 'wifi' } else { 'ethernet' }
        }
    }
)
$allMacs    = @($allNics | ForEach-Object { $_['mac'] })
$primaryNic = ($allNics | Where-Object { $_['type'] -eq 'ethernet' } | Select-Object -First 1)
if (-not $primaryNic) { $primaryNic = ($allNics | Select-Object -First 1) }
$primaryMac = if ($primaryNic) { $primaryNic['mac'] } else { '' }

# --- Detect Hardware --------------------------------------------------------

Write-Host '  -- Hardware Detected ----------------------------------' -ForegroundColor DarkCyan
Write-Host "    Manufacturer : $hwMfr"
Write-Host "    Model        : $hwModel"
Write-Host "    Serial       : $(if ($serialClean) { $hwSerial } else { '(no usable serial)' })"
Write-Host "    NICs         : $($allNics.Count) physical ($(@($allNics | Where-Object { $_['type'] -eq 'ethernet' }).Count) wired)"

Write-Host ''

Invoke-DriverCoverageCheck -DeployShare $DeployShare -Manufacturer $hwMfr -Model $hwModel

# --- Inventory preflight lookup ---------------------------------------------
# Look up this machine by serial number to pre-populate defaults.
# Fails silently - deployment always continues if the API is unreachable.

$prior = $null
if ($serialClean) {
    try {
        $results = Invoke-RestMethod "$InvApi/api/devices?q=$([uri]::EscapeDataString($hwSerial))" `
            -TimeoutSec 5 -ErrorAction Stop
        # Find exact serial match (search returns partial matches too)
        $match = @($results | Where-Object { $_.serial_number -ieq $hwSerial }) | Select-Object -First 1
        if (-not $match) { $match = @($results) | Select-Object -First 1 }
        if ($match) {
            # Map inventory OS string to local os_key ('1'=Win11Home, '2'=Win11Pro, '3'=Win10Pro)
            $osKeyFromInv = switch -Wildcard ($match.os) {
                '*11*Home*'  { '1' }
                '*11*Pro*'   { '2' }
                '*10*'       { '3' }
                default      { '2' }   # default to Win11 Pro
            }
            $prior = [PSCustomObject]@{
                device_id = $match.id
                hostname  = $match.hostname
                os        = $match.os
                os_key    = $osKeyFromInv
                last_seen = $match.last_seen
            }
        }
    } catch { $prior = $null }
}

# --- OS + Computer Name selection -------------------------------------------
# Known machine: show inventory defaults with 30 s countdown.
# Unknown machine: prompt as normal.

$osKey        = ''
$computerName = ''
$useDefaults  = $false

if ($prior) {
    Write-Host '  -- Inventory match found --------------------------------' -ForegroundColor Green
    Write-Host "    Name:      $($prior.hostname)" -ForegroundColor Green
    Write-Host "    Last OS:   $($prior.os)" -ForegroundColor DarkGray
    if ($prior.last_seen) { Write-Host "    Last seen: $($prior.last_seen)" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "  Default OS:   [$($prior.os_key)] $($OsOptions[$prior.os_key].Label)" -ForegroundColor Cyan
    Write-Host "  Default Name: $($prior.hostname)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press any key to change, or wait 30 s to accept defaults.' -ForegroundColor DarkGray
    Write-Host ''

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $true
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null; $timedOut = $false; break }
        $secsLeft = [int](30 - $sw.Elapsed.TotalSeconds)
        Write-Host "`r  Auto-accepting in $secsLeft s...  " -NoNewline
        Start-Sleep -Milliseconds 200
    }
    Write-Host ''; $sw.Stop()

    if ($timedOut) {
        $osKey       = $prior.os_key
        $computerName = $prior.hostname.ToUpper()
        $useDefaults  = $true
        Write-Host "  Using: $($OsOptions[$osKey].Label) / $computerName" -ForegroundColor Green
        Write-Host ''
    } else {
        Write-Host '  Manual selection.' -ForegroundColor Yellow; Write-Host ''
    }
}

# --- OS Selection (manual) --------------------------------------------------

if (-not $useDefaults) {
    Write-Host '  Select OS to deploy:' -ForegroundColor Cyan
    foreach ($k in ($OsOptions.Keys | Sort-Object)) {
        Write-Host "    [$k] $($OsOptions[$k].Label)"
    }
    Write-Host ''
    while ($osKey -notin $OsOptions.Keys) { $osKey = Read-Host '  Choice' }
}

$os = $OsOptions[$osKey]
$wimPath = Join-Path $DeployShare $os.WimFile
if (-not (Test-Path $wimPath)) {
    Write-Host "  WIM not found: $wimPath" -ForegroundColor Red
    Write-Host "  Export with: dism /Export-Image /SourceImageFile:<iso-install.wim> /SourceIndex:<n> /DestinationImageFile:C:\deploy\images\$($os.WimFile | Split-Path -Leaf) /Compress:fast" -ForegroundColor Yellow
    Read-Host '  Press Enter to reboot'; wpeutil reboot; exit
}

# --- Computer Name (manual) -------------------------------------------------

if (-not $useDefaults) {
    Write-Host ''
    Write-Host '  Computer name: (1-15 chars, letters/numbers/hyphens e.g. JUNIPER-WS-01)' -ForegroundColor Cyan
    Write-Host ''
    while ($true) {
        $computerName = (Read-Host '  Name').Trim().ToUpper()
        if ($computerName -match '^[A-Z0-9]([A-Z0-9\-]{0,13}[A-Z0-9])?$' -and
            $computerName.Length -ge 1 -and $computerName.Length -le 15) { break }
        Write-Host '    Invalid. Letters/numbers/hyphens, max 15 chars.' -ForegroundColor Yellow
    }
}

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
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Partitioned: S: (EFI), C: (Windows).' -ForegroundColor Green

# --- Apply WIM --------------------------------------------------------------

Write-Host ''
Write-Host "  Applying $($os.Label) (index $($os.WimIndex))..." -ForegroundColor Cyan
Write-Host '  This takes 10-20 minutes depending on disk speed.'
Write-Host ''
$p = Start-Process dism -ArgumentList "/Apply-Image /ImageFile:`"$wimPath`" /Index:$($os.WimIndex) /ApplyDir:C:\" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  DISM apply failed (exit $($p.ExitCode))" -ForegroundColor Red
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Image applied.' -ForegroundColor Green

# --- Inject Drivers (offline) -----------------------------------------------

Write-Host ''
Write-Host '  Injecting hardware drivers...' -ForegroundColor Cyan
Invoke-DriverInjection -DeployShare $DeployShare -Manufacturer $hwMfr -Model $hwModel

# --- Inject unattend.xml with computer name ---------------------------------

Write-Host ''
Write-Host '  Writing unattend.xml...' -ForegroundColor Cyan
$unattendSrc = Join-Path $DeployShare $os.Unattend
if (-not (Test-Path $unattendSrc)) {
    Write-Host "  WARN: Unattend not found at $unattendSrc - skipping." -ForegroundColor Yellow
} else {
    New-Item 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null
    $xml = (Get-Content $unattendSrc -Raw) -replace '<ComputerName>\*</ComputerName>', "<ComputerName>$computerName</ComputerName>"
    $xml | Set-Content 'C:\Windows\Panther\unattend.xml' -Encoding UTF8
    Write-Host "  unattend.xml written (ComputerName=$computerName)." -ForegroundColor Green
}

# --- Pre-register in inventory ----------------------------------------------
# Uses the inventory agent directly - same data gathering as post-install.
# $JUNIPER_HOSTNAME_OVERRIDE passes the target computer name since WinPE
# reports 'MINWINPC' for $env:COMPUTERNAME.

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
    # PATCH: record the chosen OS and imaging note
    if ($invDeviceId) {
        $today     = (Get-Date -Format 'yyyy-MM-dd')
        $patchBody = "{`"os`":`"$($os.Label)`",`"os_version`":`"`",`"notes`":`"Imaged $today - Juniper IT`"}"
        Invoke-RestMethod "$InvApi/api/device/$invDeviceId" -Method PATCH -Body $patchBody `
            -ContentType 'application/json' -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    }
} catch {
    Write-Host '  Inventory registration skipped (server unreachable - will register post-install).' -ForegroundColor DarkGray
}

# --- Boot sector ------------------------------------------------------------

Write-Host ''
Write-Host '  Configuring UEFI boot...' -ForegroundColor Cyan
$p = Start-Process bcdboot -ArgumentList 'C:\Windows /s S: /f UEFI' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Write-Host "  bcdboot failed (exit $($p.ExitCode))" -ForegroundColor Red
    Read-Host '  Press Enter to exit'; exit
}
Write-Host '  Boot sector configured.' -ForegroundColor Green

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

# --- Cleanup and reboot -----------------------------------------------------

try { net use $DeployShare /delete *>$null } catch {}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Green
Write-Host "   Done: $($os.Label) -> $computerName" -ForegroundColor Green
Write-Host '   Rebooting in 15 seconds...               ' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''
Start-Sleep 15
wpeutil reboot
