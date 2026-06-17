# install_agent.ps1  -  Juniper Design Inventory Agent
# Served dynamically by the inventory server; ##INVENTORY_API## is replaced at serve time.
#
# One-liner install / update:
#   irm http://inventory.juniperdesign.local:8080/static/install_agent.ps1 | iex
#
# What this does:
#   1. Collects machine identity + full hardware snapshot from WMI
#   2. POSTs to /ingest/endpoint to register or update this device in the inventory DB
#   3. Gracefully skips sections that aren't available (VMs, headless, etc.)

$ErrorActionPreference = 'SilentlyContinue'
$InvApi   = '##INVENTORY_API##'
$AgentVer = '1.0.0'

# -- Helpers ------------------------------------------------------------------

function Get-MacAddresses {
    Get-WmiObject Win32_NetworkAdapterConfiguration |
        Where-Object { $_.MACAddress -and $_.IPEnabled } |
        Select-Object -ExpandProperty MACAddress |
        ForEach-Object { $_.Replace('-', ':').ToLower() }
}

function Get-PrimaryIP {
    Get-WmiObject Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
        Select-Object -First 1 |
        ForEach-Object {
            $_.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        }
}

# -- Collect WMI data ----------------------------------------------------------

$cs   = Get-WmiObject Win32_ComputerSystem
$os   = Get-WmiObject Win32_OperatingSystem
$bios = Get-WmiObject Win32_BIOS
$cpu  = Get-WmiObject Win32_Processor | Select-Object -First 1
$enc  = Get-WmiObject Win32_SystemEnclosure | Select-Object -First 1
$gpu  = Get-WmiObject Win32_VideoController | Select-Object -First 1

$disks   = @(Get-WmiObject Win32_DiskDrive)
$ramGb   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$diskGb  = [math]::Round(($disks | Measure-Object -Property Size -Sum).Sum / 1GB, 0)
$gpuVram = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 1) } else { $null }

$macs      = @(Get-MacAddresses)
$primaryIp = Get-PrimaryIP

# Chassis type lookup (SMBIOS values)
$chassisMap = @{
    3='Desktop'; 4='Low Profile Desktop'; 5='Pizza Box'; 6='Mini Tower';
    7='Tower'; 8='Portable'; 9='Laptop'; 10='Notebook'; 11='Hand Held';
    12='Docking Station'; 13='All in One'; 14='Sub Notebook'; 15='Space Saving';
    16='Lunch Box'; 17='Main Server Chassis'; 23='Rack Mount Chassis';
    24='Sealed-Case PC'; 30='Tablet'; 31='Convertible'; 32='Detachable'
}
$chassisType = $null
if ($enc.ChassisTypes) {
    $chassisType = $chassisMap[[int]($enc.ChassisTypes | Select-Object -First 1)]
}

# -- Security / compliance info ------------------------------------------------

$blState = $null
try {
    $bl = Get-WmiObject -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
            -Class Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
    if ($bl) {
        $blMap = @{ 0='Fully Decrypted'; 1='Fully Encrypted'; 2='Encryption In Progress';
                    3='Decryption In Progress'; 4='Encryption Paused'; 5='Decryption Paused' }
        $ps      = $bl.GetProtectionStatus().protectionStatus
        $blState = $blMap[[int]$ps]
    }
} catch {}

$defEnabled  = $null
$defRealtime = $null
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $defEnabled  = [bool]$mp.AntivirusEnabled
    $defRealtime = [bool]$mp.RealTimeProtectionEnabled
} catch {}

$tpmPresent = $null
try { $tpmPresent = [bool](Get-Tpm -ErrorAction Stop).TpmPresent } catch {}

$secureBoot = $null
try { $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch {}

# -- Installed software snapshot -----------------------------------------------

$software = @()
try {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $software = @(
        Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object -Property @{n='name';e={$_.DisplayName}},
                                    @{n='version';e={$_.DisplayVersion}},
                                    @{n='publisher';e={$_.Publisher}},
                                    @{n='install_date';e={$_.InstallDate}} |
            Sort-Object name
    )
} catch {}

# -- Build payload -------------------------------------------------------------

$payload = [ordered]@{
    agent_version   = $AgentVer
    computer_name   = $env:COMPUTERNAME
    hostname        = $env:COMPUTERNAME
    mac             = $macs | Select-Object -First 1
    macs            = $macs
    ip              = $primaryIp
    manufacturer    = $cs.Manufacturer
    model           = $cs.Model
    bios_serial     = $bios.SerialNumber
    chassis_serial  = $enc.SerialNumber
    bios_version    = $bios.SMBIOSBIOSVersion
    chassis_type    = $chassisType
    os_caption      = $os.Caption
    os_version      = $os.Version
    os_build        = $os.BuildNumber
    cpu_name        = ($cpu.Name -replace '\s+', ' ').Trim()
    cpu_cores       = [int]$cpu.NumberOfCores
    cpu_threads     = [int]$cpu.NumberOfLogicalProcessors
    ram_gb          = $ramGb
    disk_total_gb   = $diskGb
    gpu_name        = $gpu.Name
    gpu_vram_gb     = $gpuVram
    bitlocker_state = $blState
    defender_enabled = $defEnabled
    tpm_present     = $tpmPresent
    secure_boot     = $secureBoot
    domain_joined   = [bool]$cs.PartOfDomain
    domain          = $cs.Domain
    software        = $software
    raw             = @{
        bios_date       = $bios.ReleaseDate
        os_install_date = $os.InstallDate
        gpu_driver      = $gpu.DriverVersion
        total_disk_count = $disks.Count
    }
}

# -- POST to inventory ---------------------------------------------------------

try {
    $body = $payload | ConvertTo-Json -Depth 6
    $r    = Invoke-RestMethod "$InvApi/ingest/endpoint" `
                -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
    Write-Host "  Inventory: registered device_id=$($r.device_id) ($env:COMPUTERNAME)" -ForegroundColor Green
} catch {
    Write-Host "  WARN: Inventory check-in failed: $_" -ForegroundColor Yellow
    Write-Host "  Retry: irm $InvApi/static/install_agent.ps1 | iex"
}

