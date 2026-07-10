#Requires -Version 5.1
<#
build-lenovo-manifest.ps1
--------------------------------------------------------------------------------
Auto-generates a per-machine-type Lenovo SoftPaq driver manifest from Lenovo's
public Update Retriever catalog:

    https://download.lenovo.com/catalog/<MT>_<OS>.xml

The catalog lists every driver package for a machine type; each entry points to a
per-package descriptor XML that carries the installer .exe name, version, category
and PnP IDs. This tool resolves all of that and writes

    <OutDir>\<MT>-driver-manifest.json

in the exact schema consumed by sync-lenovo-drivers.ps1 (DB upsert) and
curate-lenovo-model.ps1 (download + silent extract + keep .inf). This removes the
old hand-assembly of Lenovo manifests.

sha256/size_bytes are intentionally left blank/0: curate.ps1 computes the real
SHA256 when it downloads each .exe, and the promote step backfills it. Keeping
generation to XML-only keeps it fast (no multi-GB downloads at manifest time).

Usage (run on pc-deploy - needs outbound HTTPS to download.lenovo.com):
    .\build-lenovo-manifest.ps1 -MachineType 83JU -Os Win11
--------------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $MachineType,      # e.g. 83JU
    [string] $Os        = 'Win11',                     # Win11 | Win10
    [string] $OutDir    = 'C:\deploy\scripts',
    [int]    $ThrottleMs = 120
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-LenovoXml([string]$Url) {
    $raw = (New-Object System.Net.WebClient).DownloadString($Url)
    $raw = $raw.TrimStart([char]0xFEFF, [char]0x200B)          # strip BOM / zero-width
    $lt  = $raw.IndexOf('<')
    if ($lt -gt 0) { $raw = $raw.Substring($lt) }
    [xml]$raw
}

# Lenovo catalog category string -> local subdir slug.
# Slugs line up with the category map in sync-lenovo-drivers.ps1.
function Get-Subdir([string]$cat) {
    switch -Regex ($cat) {
        # NB: order matters. Lenovo's motherboard/chipset category string literally
        # contains the word "video" ("...onboard video PCIe switches"), so Chipset
        # must be tested BEFORE Display/Video or AMD chipset/NPU/platform land in display.
        'BIOS|UEFI|Embedded Controller' { 'bios';        break }
        'Firmware'                      { 'firmware';    break }
        'Chipset|Motherboard'           { 'chipset';     break }
        'Audio'                         { 'audio';       break }
        'Camera'                        { 'camera';      break }
        'Bluetooth'                     { 'bluetooth';   break }
        'Wireless WAN|WWAN'             { 'wireless';    break }
        'Wireless LAN|WLAN'             { 'wifi';        break }
        'LAN|Ethernet|Network'          { 'network';     break }
        'Fingerprint'                   { 'fingerprint'; break }
        'Mouse|Pen|Keyboard'            { 'input';       break }
        'Touchpad|Pointing'             { 'touchpad';    break }
        'Display|Video|Graphic'         { 'display';     break }
        'Storage|SATA|NVMe|SSD'         { 'storage';     break }
        'Power'                         { 'power';       break }
        default                         { 'other' }
    }
}
function Test-IsBios([string]$cat) { return [bool]($cat -match 'BIOS|UEFI|Embedded Controller') }

$catUrl = "https://download.lenovo.com/catalog/${MachineType}_${Os}.xml"
Write-Host "Catalog: $catUrl" -ForegroundColor Cyan
$cat = Get-LenovoXml $catUrl
$pkgNodes = @($cat.packages.package)
Write-Host "Packages listed in catalog: $($pkgNodes.Count)" -ForegroundColor Cyan
if ($pkgNodes.Count -eq 0) { throw "No packages in catalog for $MachineType ($Os)." }

$out = New-Object System.Collections.Generic.List[object]
$idx = 0
foreach ($p in $pkgNodes) {
    $idx++
    $loc  = [string]$p.location
    $cCat = [string]$p.category
    if (-not $loc) { continue }

    try { $d = Get-LenovoXml $loc }
    catch { Write-Warning "[$idx/$($pkgNodes.Count)] descriptor fetch failed: $loc"; continue }

    $pkg = $d.Package
    $id  = [string]$pkg.id
    $ver = [string]$pkg.version
    $title = ''
    $tn = $d.SelectSingleNode('//Title/Desc'); if ($tn) { $title = $tn.InnerText.Trim() }

    # installer exe: prefer an .exe under Files/Installer/File/Name
    $exe = $null; $size = 0
    $nameNodes = $d.SelectNodes('//Files/Installer/File/Name')
    if ($nameNodes -and $nameNodes.Count -gt 0) {
        foreach ($nn in $nameNodes) { if ($nn.InnerText -match '\.exe$') { $exe = $nn.InnerText.Trim(); break } }
        if (-not $exe) { $exe = $nameNodes[0].InnerText.Trim() }
    }
    if (-not $exe) { Write-Warning "[$idx/$($pkgNodes.Count)] no installer exe: $loc"; continue }
    $szNode = $d.SelectSingleNode('//Files/Installer/File/Size')
    if ($szNode) { [int64]$tmp = 0; if ([int64]::TryParse($szNode.InnerText.Trim(), [ref]$tmp)) { $size = $tmp } }

    $base = $loc.Substring(0, $loc.LastIndexOf('/') + 1)
    $url  = $base + $exe

    # PnP hardware IDs (best-effort, for notes/matching)
    $pnp = New-Object System.Collections.Generic.List[string]
    foreach ($n in $d.SelectNodes('//DetectInstall//HardwareID')) { if ($n.InnerText) { $pnp.Add($n.InnerText.Trim()) } }
    foreach ($n in $d.SelectNodes('//DetectVersion/_PnPID'))       { if ($n.InnerText) { $pnp.Add($n.InnerText.Trim()) } }
    $pnpArr = @($pnp | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 24)

    $out.Add([ordered]@{
        name       = $id
        title      = $title
        version    = $ver
        category   = $cCat
        subdir     = (Get-Subdir $cCat)
        filename   = $exe
        url        = $url
        sha256     = ''
        size_bytes = $size
        pnp_id     = $pnpArr
        is_bios    = (Test-IsBios $cCat)
    })
    Start-Sleep -Milliseconds $ThrottleMs
}

if ($out.Count -eq 0) { throw "Resolved 0 packages for $MachineType." }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outPath = Join-Path $OutDir "$MachineType-driver-manifest.json"
$json = $out | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Wrote $($out.Count) packages -> $outPath" -ForegroundColor Green
$out | Group-Object subdir | Sort-Object Name | ForEach-Object { "  {0,-12} {1}" -f $_.Name, $_.Count }
"  is_bios/firmware (skipped by curate): {0}" -f (@($out | Where-Object { $_.is_bios }).Count)
