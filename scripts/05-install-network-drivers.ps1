# 05-install-network-drivers.ps1
# Installs NETWORK drivers (Wi-Fi / Ethernet / Bluetooth) BEFORE the join-wifi
# phase, so a wireless adapter actually exists when we try to connect. Runs on the
# first post-OOBE boot while the imaging Ethernet (USB-C dongle) is still connected,
# so the online sources below are reachable.
#
# Why this phase exists: join-wifi used to run first, before ANY driver install.
# On models whose Wi-Fi driver was not injected offline in WinPE (un-curated
# models), there was no wireless adapter yet, so join-wifi silently skipped - and
# once the imaging dongle came out the machine had no network at all. Installing
# the network drivers first fixes that.
#
# Sources, in order (each best-effort):
#   1. Inventory driver catalog - confirmed_working NETWORK drivers for this model
#      (curated models: exact vendor .inf/.exe/.msi).
#   2. Windows Update - driver-class updates scoped to Net + Bluetooth (un-curated
#      models: pulls the OEM Wi-Fi driver from Microsoft's driver catalog).
#   3. pnputil /scan-devices to bind any staged drivers, then wait for the adapter.
#
# BEST-EFFORT / non-fatal: any failure exits 0 so imaging never aborts. If a WU
# network driver needs a reboot to activate, returns 3010 so the orchestrator
# reboots and re-runs this phase (the adapter is then present and it advances).

param(
    [string]$InvApi        = 'http://192.168.5.141:8080',
    [string]$DriverRoot    = '\\192.168.5.141\deploy$\drivers',
    [int]   $WaitAdapterSec = 60
)
$ErrorActionPreference = 'Stop'
trap { Write-Host "WARN: network-driver install hit a non-fatal error: $_" -ForegroundColor Yellow; exit 0 }

try { . 'C:\ProgramData\JuniperSetup\progress.ps1' } catch {}
if (-not (Get-Command Publish-Event -ErrorAction SilentlyContinue)) {
    function Publish-Event { param([Parameter(ValueFromRemainingArguments)]$a) }
}

function Test-WifiPresent {
    [bool](Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.PhysicalMediaType -match 'Native 802.11|Wireless' -or
        $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' })
}

Publish-Event -PhaseKey 'install-network-drivers' -Step 'start' -Status 'running' -Message 'Installing network drivers before Wi-Fi join'

if (Test-WifiPresent) {
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'detect' -Status 'info' -Message 'Wi-Fi adapter already present'
}

# --- 0. ACTIVELY install the universal USB-C/dock Ethernet drivers -----------
# CRITICAL for USB-C dongles (e.g. Lenovo ThinkPad USB-C Ethernet, VID_17EF&PID_720C):
# deploy.ps1 offline-DISM-injects these into the store, but Windows does NOT auto-bind
# an offline-injected driver to a Class_FF USB NIC that is already present at first
# boot - it sits 'Unknown' until the driver is *actively* installed (or the device is
# hot-replugged). `pnputil /add-driver <inf> /install` actively installs AND binds
# matching present devices, which is exactly what makes the dongle come up wired here.
# deploy.ps1 stages the _universal tree locally at $UniLocal so this needs no network.
$UniLocal = 'C:\ProgramData\JuniperSetup\universal-drivers'
try {
    if (Test-Path $UniLocal) {
        $uInf = @(Get-ChildItem $UniLocal -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)
        Write-Host "Actively installing $($uInf.Count) universal USB-Ethernet driver(s) to force bind..." -ForegroundColor Cyan
        foreach ($f in $uInf) {
            try { Start-Process pnputil.exe -ArgumentList "/add-driver `"$($f.FullName)`" /install" -Wait -NoNewWindow } catch {}
        }
        # Restart any Unknown USB net node so it re-evaluates the now-installed driver.
        try {
            Get-PnpDevice -Class Net -Status Error,Unknown -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like 'USB\*' } |
                ForEach-Object { Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue;
                                 Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
        } catch {}
        Start-Process pnputil.exe -ArgumentList '/scan-devices' -Wait -NoNewWindow
        Publish-Event -PhaseKey 'install-network-drivers' -Step 'universal' -Status 'ok' -Message "Actively installed $($uInf.Count) universal USB-Ethernet driver(s)"
    } else {
        Publish-Event -PhaseKey 'install-network-drivers' -Step 'universal' -Status 'info' -Message 'No local universal-drivers folder - relying on offline injection'
    }
} catch {
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'universal' -Status 'warning' -Message "Universal active-install step: $($_.Exception.Message)"
}

# --- 1. Catalog network drivers ---------------------------------------------
# Network is special: getting the machine online is worth installing ANY on-disk
# network driver, not only status=confirmed_working ones. We query every status,
# prefer confirmed_working, and the Test-Path gate below silently skips catalog
# rows whose file was never downloaded to the share (common for un-curated models -
# those fall through to the Windows Update pass in step 2).
$netMatch = 'net|wi.?fi|wireless|bluetooth|wlan|wwan|\blan\b|ethernet'
try {
    $cs    = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $mfr   = "$($cs.Manufacturer)".Trim()
    $model = "$($cs.Model)".Trim()
    $osc   = "$((Get-WmiObject Win32_OperatingSystem).Caption)"
    $os    = if ($osc -imatch 'Windows 10') { 'Windows 10' } else { 'Windows 11' }
    $url = "$InvApi/api/drivers?manufacturer=$([uri]::EscapeDataString($mfr))" +
           "&model=$([uri]::EscapeDataString($model))" +
           "&os_filter=$([uri]::EscapeDataString($os))"
    $net = @(Invoke-RestMethod $url -TimeoutSec 15 -ErrorAction Stop |
             Where-Object { "$($_.category)" -imatch $netMatch } |
             Sort-Object @{ E = { if ($_.status -eq 'confirmed_working') { 0 } else { 1 } } })
    Write-Host "Catalog network drivers for '$model': $($net.Count) (any status)" -ForegroundColor Cyan
    foreach ($d in $net) {
        $p = if ($d.unc_path) { $d.unc_path } elseif ($d.file_path) { Join-Path $DriverRoot $d.file_path } else { $null }
        if (-not $p -or -not (Test-Path $p)) { continue }
        $ext = [IO.Path]::GetExtension($p).ToLower()
        try {
            if     ($ext -eq '.inf') { Start-Process pnputil.exe -ArgumentList "/add-driver `"$p`" /install" -Wait -NoNewWindow }
            elseif ($ext -eq '.msi') { Start-Process msiexec.exe -ArgumentList "/i `"$p`" /qn /norestart" -Wait -NoNewWindow }
            elseif ($ext -eq '.exe') { $sa = if ($d.notes -imatch 'silent:\s*(.+)') { $matches[1].Trim() } else { '/s /norestart' }; Start-Process $p -ArgumentList $sa -Wait -NoNewWindow }
            Write-Host "  installed: $($d.driver_name)" -ForegroundColor Green
        } catch { Write-Host "  WARN $($d.driver_name): $_" -ForegroundColor Yellow }
    }
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'catalog' -Status 'ok' -Message "Catalog network drivers: $($net.Count) processed"
} catch {
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'catalog' -Status 'warning' -Message "Catalog step: $($_.Exception.Message)"
}

# --- 2. Windows Update: network-class driver updates (un-curated models) -----
$wuReboot = $false
if (-not (Test-WifiPresent)) {
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'wu-drivers' -Status 'running' -Message 'Searching Windows Update for network drivers'
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res      = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $want     = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $res.Updates) {
            $dc = ''
            try { $dc = "$($u.DriverClass)" } catch {}
            if ($dc -imatch '^(net|bluetooth)') { [void]$want.Add($u) }
        }
        Write-Host "WU network-class driver updates: $($want.Count)" -ForegroundColor Cyan
        if ($want.Count -gt 0) {
            $dl = $session.CreateUpdateDownloader(); $dl.Updates = $want; [void]$dl.Download()
            $inst = $session.CreateUpdateInstaller(); $inst.Updates = $want; $ir = $inst.Install()
            $wuReboot = [bool]$ir.RebootRequired
            Write-Host "  WU net-driver install rc=$($ir.ResultCode) reboot=$wuReboot" -ForegroundColor Green
        }
        Publish-Event -PhaseKey 'install-network-drivers' -Step 'wu-drivers' -Status 'ok' -Message "Windows Update network drivers: $($want.Count) installed"
    } catch {
        Publish-Event -PhaseKey 'install-network-drivers' -Step 'wu-drivers' -Status 'warning' -Message "WU network-driver step: $($_.Exception.Message)"
    }
}

# --- 3. PnP rescan + wait for the wireless adapter to enumerate --------------
try { Start-Process pnputil.exe -ArgumentList '/scan-devices' -Wait -NoNewWindow } catch {}
$deadline = (Get-Date).AddSeconds($WaitAdapterSec)
while (-not (Test-WifiPresent) -and (Get-Date) -lt $deadline) { Start-Sleep 5 }

if (Test-WifiPresent) {
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'verify' -Status 'ok' -Message 'Wi-Fi adapter present - ready to join Wi-Fi'
    exit 0
}
if ($wuReboot) {
    # A network driver needs a reboot to activate; reboot and re-run this phase so
    # the adapter is present before join-wifi (the next phase).
    Publish-Event -PhaseKey 'install-network-drivers' -Step 'verify' -Status 'running' -Message 'Network driver installed - rebooting to activate the adapter'
    exit 3010
}
Publish-Event -PhaseKey 'install-network-drivers' -Step 'verify' -Status 'warning' -Message 'No Wi-Fi adapter after driver install (desktop or no WLAN card) - continuing'
exit 0
