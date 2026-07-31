# fetch-hp-catalog.ps1  (HP CMSL edition, 2026-07)
# Builds an HP SoftPaq DRIVER manifest for a platform, using HP CMSL (Get-SoftpaqList).
#
# WHY THIS WAS REWRITTEN: HP retired the old per-platform catalog at
#   https://ftp.hp.com/pub/caps-softpaq/cmdownloads/{PlatformId}.cab
# (it now 404s for every platform), which silently broke all HP driver discovery.
# CMSL talks to HP's current SoftPaq service and returns each SoftPaq's real
# download .url on ftp.hp.com/pub/softpaq/, so we keep the rest of the pipeline
# (discover-drivers.ps1 curl-downloads + silent-extracts + registers) unchanged.
#
# REQUIRES: HPCMSL available to Windows PowerShell 5.1
#   (C:\Program Files\WindowsPowerShell\Modules\HPCMSL). No Intune/enrollment.
#
# OUTPUT: JSON array (the shape discover-drivers.ps1 consumes), Driver category only:
#   [ { id, name, version, category, url, filename, subdir }, ... ]
#
# USAGE:
#   .\fetch-hp-catalog.ps1 -PlatformId 89C6 -Model "HP ZBook Fury 16 G9 ..." `
#       -OsFilter win11_64 -OutFile C:\deploy\scripts\hp-89c6-manifest.json

param(
    [Parameter(Mandatory)][string]$PlatformId,   # HP SysId, 4 hex chars (Win32_BaseBoard.Product), e.g. 89C6
    [Parameter(Mandatory)][string]$Model,
    [string]$OsFilter = 'win11_64',              # win11_64 | win10_64
    [string]$OutFile  = ''
)
$ErrorActionPreference = 'Stop'

# Normalise platform id. Strip a genuine '0x' prefix only -- the old code used
# TrimStart('0x') which incorrectly ate any leading '0' or 'x' characters.
$PlatformId = $PlatformId.Trim().ToUpper()
if ($PlatformId.StartsWith('0X')) { $PlatformId = $PlatformId.Substring(2) }
if ($PlatformId -notmatch '^[0-9A-F]{4}$') {
    throw "PlatformId must be a 4-hex-char HP SysId (e.g. 89C6). Got: '$PlatformId'"
}

if (-not $OutFile) { $OutFile = "C:\deploy\scripts\hp-$($PlatformId.ToLower())-manifest.json" }

$os     = if ($OsFilter -match '10') { 'win10' } else { 'win11' }
$osVers = if ($os -eq 'win11') { @('24H2','23H2','22H2','21H2') } else { @('22H2','21H2') }

Import-Module HPCMSL -ErrorAction Stop

# Query the current OS build list; take the first OsVer that returns SoftPaqs so a
# newer/older image still resolves.
$list = $null
foreach ($ov in $osVers) {
    try {
        $l = @(Get-SoftpaqList -Platform $PlatformId -Os $os -OsVer $ov -ErrorAction Stop)
        if ($l.Count) { Write-Host "CMSL: $($l.Count) SoftPaqs for $PlatformId $os/$ov"; $list = $l; break }
    } catch { Write-Host "  ($os/${ov}: $($_.Exception.Message))" }
}
if (-not $list) { throw "HP CMSL returned no SoftPaqs for platform $PlatformId ($os $($osVers -join '/'))." }

# Category -> on-disk subdir, using the keys Register-OnDisk's CAT map understands
# so extracted .inf files get categorised (Network/Storage/Display/Audio/Chipset...).
function Map-Sub([string]$cat) {
    switch -Regex ($cat) {
        'Network'                { 'network';  break }
        'Storage'                { 'storage';  break }
        'Graphics|Video|Display' { 'graphics'; break }
        'Audio'                  { 'audio';    break }
        'Bluetooth'              { 'bluetooth';break }
        'Keyboard|Mouse|Input'   { 'input';    break }
        'Chipset|Enabling'       { 'chipset';  break }
        default                  { 'chipset' }
    }
}

$manifest = @()
foreach ($sp in $list) {
    if ("$($sp.Category)" -notlike 'Driver*') { continue }   # DRIVERS only (skip BIOS/firmware/software/dock)
    if (-not $sp.url) { continue }
    $manifest += [ordered]@{
        id       = "$($sp.id)"
        name     = "$($sp.Name)"
        version  = "$($sp.Version)"
        category = "$($sp.Category)"
        url      = "$($sp.url)"
        filename = (($sp.url -split '/')[-1])
        subdir   = (Map-Sub "$($sp.Category)")
    }
}
if ($manifest.Count -eq 0) { throw "No Driver-category SoftPaqs for platform $PlatformId." }

# Emit a JSON ARRAY even when there is a single item (PS 5.1 unwraps single-element
# arrays, so force the brackets).
$json = if ($manifest.Count -eq 1) { "[" + ($manifest[0] | ConvertTo-Json -Depth 5) + "]" }
        else { $manifest | ConvertTo-Json -Depth 5 }
Set-Content -Path $OutFile -Value $json -Encoding UTF8
Write-Host "Wrote $($manifest.Count) driver SoftPaqs -> $OutFile"
