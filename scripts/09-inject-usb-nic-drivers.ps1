# 09-inject-usb-nic-drivers.ps1
# Injects USB NIC drivers from the host DriverStore into the WinPE WIM.
#
# Targets:
#   usbnet.inf    -- Windows USB network class driver (covers ASIX AX88179/AX88178A,
#                    AX88179A, Lenovo USB-C NIC, and many others)
#   rtump64x64    -- Realtek USB MultiFunction NIC (RTL8153/8156 -- common USB-C adapters)
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

# 3. Any other USB net-class INFs we might have missed (ASIX AX88179, AX88772, etc.)
$others = Get-ChildItem $repo -Filter '*.inf' -Recurse |
    Where-Object { $_.Name -match 'ax88|asix|usbgige|usbnet2|cdc_ncm' } |
    Select-Object -ExpandProperty DirectoryName -Unique
foreach ($o in $others) {
    $leaf = Split-Path $o -Leaf
    $dst = "$drvStage\$leaf"
    Copy-Item $o $dst -Recurse -Force
    Log "Staged extra: $leaf"
}

# 4. Online fallback: download ASIX AX88179 driver from ASIX website if not in DriverStore
$asixAlreadyStaged = (Get-ChildItem $drvStage -Filter 'netax88179*.inf' -Recurse).Count -gt 0
if (-not $asixAlreadyStaged) {
    Log 'ASIX AX88179 not in DriverStore -- downloading from ASIX...'
    $asixZip  = 'C:\imaging-build\asix-ax88179.zip'
    $asixDir  = 'C:\imaging-build\asix-ax88179'
    # ASIX official Windows driver package (AX88179/AX88178A Win10/11)
    $asixUrl  = 'https://www.asix.com.tw/en/support/download/file/asix-ax88179-178a-windows-driver'
    # Fallback: use the known-good Lenovo/Microsoft catalog URL which hosts the same driver
    $fallbackUrl = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2024/05/f8a09fa9-c1e2-4d62-a4a8-c1f69c8af1c7_59b2b9f3cce3e6d0e80a63e2c9bf1f21ef5c9cce.cab'
    try {
        Log "Downloading ASIX driver package..."
        Invoke-WebRequest -Uri $fallbackUrl -OutFile $asixZip -UseBasicParsing -TimeoutSec 60
        New-Item $asixDir -ItemType Directory -Force | Out-Null
        # Extract CAB or ZIP
        if ($asixZip -match '\.cab$' -or (Get-Content $asixZip -TotalCount 1 -Encoding Byte) -match 'MSCF') {
            & expand.exe $asixZip -F:* $asixDir | Out-Null
        } else {
            Expand-Archive $asixZip -DestinationPath $asixDir -Force
        }
        $dst = "$drvStage\asix-download"
        Copy-Item $asixDir $dst -Recurse -Force
        Log "ASIX driver downloaded and staged from web."
    } catch {
        Log "WARNING: Could not download ASIX driver: $_"
        Log "You can manually download from https://www.asix.com.tw and place in C:\imaging-build\drivers\"
    }
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

# --- Inject drivers ---
Log 'Injecting drivers...'
Add-WindowsDriver -Path $mountDir -Driver $drvStage -Recurse -ForceUnsigned -ErrorAction SilentlyContinue |
    ForEach-Object { Log "  Added: $($_.Driver) ($($_.ProviderName))" }
Log 'Drivers injected.'

# --- Save WIM ---
Log 'Saving WIM...'
Dismount-WindowsImage -Path $mountDir -Save
Log "Saved. Size: $([math]::Round((Get-Item $workWim).Length/1MB)) MB"

# --- Deploy ---
Copy-Item $workWim 'C:\tftpd64\sources\boot.wim' -Force
Copy-Item $workWim 'C:\WinPE_amd64\media\sources\boot.wim' -Force
Log 'Deployed to tftpd64 and WinPE media. Done.'
Log 'Next: copy boot.wim to USB drive (D:\sources\boot.wim).'
