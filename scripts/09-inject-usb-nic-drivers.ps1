# 09-inject-usb-nic-drivers.ps1
# Injects USB NIC drivers from the host DriverStore into the WinPE WIM.
#
# Targets:
#   rtump64x64    -- Realtek RTL8152/8153/8155/8156/8157 (most USB-C Ethernet adapters,
#                    Lenovo ThinkPad USB-C Ethernet Adapter 4X90S91830, etc.)
#   netax88179    -- ASIX AX88179/AX88178A USB 3.0 Gigabit Ethernet
#   netrndis      -- Microsoft RNDIS (Lenovo USB docks presenting as RNDIS NICs)
#   rtu53cx22x64  -- Realtek USB-C 2.5G adapters
#   rtucx21x64    -- Realtek USB-C 1G adapters
#   rtux64w10     -- Realtek PCIe NIC (also handles some USB variants)
#   usbnet        -- Microsoft generic USB network class (KDNet/EEM)
#
# Must be run via Scheduled Task as SYSTEM (DISM requires elevation and
# WinRM process isolation breaks Dismount-WindowsImage -Save).
# Use wim-inject-nic-drivers.ps1 on pc-deploy to run this as a task.
#
# After running, copy the updated boot.wim to the USB drive.

$ErrorActionPreference = 'Stop'
$log = 'C:\imaging-build\inject-nic-drivers.log'
function Log($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Tee-Object $log -Append | Write-Host }

Log 'Starting USB NIC driver injection into WinPE WIM...'

$workWim  = 'C:\imaging-build\boot.wim'
$mountDir = 'C:\imaging-build\mount'
$drvStage = 'C:\imaging-build\drivers'

# --- Clean up prior state ---
try { Dismount-WindowsImage -Path $mountDir -Discard } catch {}
if (Test-Path $mountDir)  { Remove-Item $mountDir  -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $drvStage)  { Remove-Item $drvStage  -Recurse -Force -ErrorAction SilentlyContinue }
New-Item $mountDir  -ItemType Directory -Force | Out-Null
New-Item $drvStage  -ItemType Directory -Force | Out-Null

# --- Find and stage USB NIC driver packages ---
$repo = 'C:\Windows\System32\DriverStore\FileRepository'

# 1. usbnet.inf -- ASIX AX88179/AX88178 family, many USB Ethernet adapters
$usbnetDir = Get-ChildItem $repo -Filter 'usbnet.inf' -Recurse |
    Select-Object -First 1 -ExpandProperty DirectoryName
if ($usbnetDir) {
    $dst = "$drvStage\usbnet"
    Copy-Item $usbnetDir $dst -Recurse -Force
    Log "Staged usbnet.inf from $usbnetDir"
} else {
    Log 'WARNING: usbnet.inf not found in DriverStore.'
}

# 2. Realtek USB NIC (rtump64x64) -- RTL8153/RTL8156 USB-C adapters
$realtekUsb = Get-ChildItem $repo -Filter 'rtump64x64.inf' -Recurse |
    Select-Object -First 1 -ExpandProperty DirectoryName
if ($realtekUsb) {
    $dst = "$drvStage\rtump"
    Copy-Item $realtekUsb $dst -Recurse -Force
    Log "Staged rtump64x64.inf from $realtekUsb"
} else {
    Log 'NOTE: rtump64x64.inf not found (Realtek USB NIC driver not installed on host).'
}

# 3. Any other USB net-class INFs we might have missed (ASIX AX88772, etc.)
$others = Get-ChildItem $repo -Filter '*.inf' -Recurse |
    Where-Object { $_.Name -match 'ax88|asix|usbgige|usbnet2|cdc_ncm' } |
    Select-Object -ExpandProperty DirectoryName -Unique
foreach ($o in $others) {
    $leaf = Split-Path $o -Leaf
    $dst = "$drvStage\$leaf"
    Copy-Item $o $dst -Recurse -Force
    Log "Staged extra: $leaf"
}

# 3b. RNDIS -- covers Lenovo USB-C docks and other USB gadgets presenting as RNDIS NICs
foreach ($rndisName in @('netrndis.inf', 'rndiscmp.inf')) {
    $rndisDir = Get-ChildItem $repo -Filter $rndisName -Recurse |
        Select-Object -First 1 -ExpandProperty DirectoryName
    if ($rndisDir) {
        $leaf = $rndisName -replace '\.inf$', ''
        Copy-Item $rndisDir "$drvStage\$leaf" -Recurse -Force
        Log "Staged $rndisName (RNDIS) from $rndisDir"
    }
}

# 3c. Lenovo USB-C Ethernet / ThinkPad dock NICs (VID_17EF).
#     Lenovo USB-C Ethernet Adapter (4X90S91830) uses RTL8153 (VID_0BDA) but some models
#     use VID_17EF directly.  Stage any INF that references VID_17EF.
$lenovoNicDirs = @()
Get-ChildItem $repo -Filter '*.inf' -Recurse | ForEach-Object {
    if ((Select-String 'VID_17EF' $_.FullName -Quiet) -and ($lenovoNicDirs -notcontains $_.DirectoryName)) {
        $lenovoNicDirs += $_.DirectoryName
        $leaf = "lenovo_$(Split-Path $_.DirectoryName -Leaf)"
        Copy-Item $_.DirectoryName "$drvStage\$leaf" -Recurse -Force
        Log "Staged Lenovo NIC driver: $($_.Name) from $($_.DirectoryName)"
    }
}

# 4. ASIX AX88179 -- stage from DriverStore.
#    NOTE: per-package injection (section below) is required; bulk injection silently skips ASIX.
$dsAsix = Get-ChildItem $repo -Filter 'netax88179_178a.inf' -Recurse |
    Select-Object -First 1 -ExpandProperty DirectoryName
if ($dsAsix) {
    Copy-Item $dsAsix "$drvStage\asix-ds" -Recurse -Force
    Log "Staged ASIX AX88179 from DriverStore: $dsAsix"
} else {
    Log 'NOTE: netax88179_178a.inf not in DriverStore. ASIX AX88179 will not be available.'
    Log '      Install the ASIX driver on pc-deploy first (connect an AX88179 adapter or install manually).'
}

$stagedCount = (Get-ChildItem $drvStage -Filter '*.inf' -Recurse).Count
Log "Drivers staged: $stagedCount INF files in $drvStage"
if ($stagedCount -eq 0) {
    Log 'ERROR: No drivers staged. Aborting.'
    exit 1
}

# --- Copy and mount WIM ---
if (Test-Path $workWim) { Remove-Item $workWim -Force }
Copy-Item 'C:\tftpd64\sources\boot.wim' $workWim -Force
Log "Source WIM: $([math]::Round((Get-Item $workWim).Length/1MB)) MB"

Log 'Mounting WIM index 1...'
Mount-WindowsImage -ImagePath $workWim -Index 1 -Path $mountDir
Log 'Mounted.'

# --- Inject drivers (one package at a time for proper error reporting) ---
Log 'Injecting drivers...'
$injectedCount = 0
Get-ChildItem $drvStage -Directory | ForEach-Object {
    $pkgDir = $_.FullName
    $pkgName = $_.Name
    try {
        $added = Add-WindowsDriver -Path $mountDir -Driver $pkgDir -Recurse -ForceUnsigned -ErrorAction Stop
        foreach ($d in $added) {
            Log "  Added: $($d.Driver) ($($d.ProviderName)) from $pkgName"
            $injectedCount++
        }
    } catch {
        Log "  FAILED to inject $pkgName : $_"
    }
}
Log "Drivers injected: $injectedCount packages added."
if ($injectedCount -eq 0) {
    Log 'ERROR: No drivers were successfully injected. Aborting.'
    Dismount-WindowsImage -Path $mountDir -Discard
    exit 1
}

# --- Save WIM ---
Log 'Saving WIM...'
Dismount-WindowsImage -Path $mountDir -Save
Log "Saved. Size: $([math]::Round((Get-Item $workWim).Length/1MB)) MB"

# --- Deploy ---
Copy-Item $workWim 'C:\tftpd64\sources\boot.wim' -Force
Copy-Item $workWim 'C:\WinPE_amd64\media\sources\boot.wim' -Force
Log 'Deployed to tftpd64 and WinPE media. Done.'
Log 'Next: copy boot.wim to USB drive (D:\sources\boot.wim).'
