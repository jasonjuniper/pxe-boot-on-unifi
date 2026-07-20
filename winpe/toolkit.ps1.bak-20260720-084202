# toolkit.ps1 - Juniper Design WinPE Diagnostic Toolkit
#
# Baked into WinPE at X:\Windows\System32\toolkit.ps1
# Launched by deploy-boot.ps1 when T is pressed at startup.
#
# Logs every diagnostic run to:
#   1. X:\Logs\winpe-toolkit-<timestamp>.log  (always, X: is always writable in WinPE)
#   2. \\192.168.5.141\deploy$\logs\<mac>-<timestamp>.log  (when share is reachable)
#   3. POST to http://192.168.5.141:8080/ingest/winpe-event  (best-effort when network is up)

param(
    [string]$DeployServer = '192.168.5.141',
    [string]$DeployShare  = '\\192.168.5.141\deploy$',
    [string]$InventoryApi = 'http://192.168.5.141:8080',
    [string]$Router       = '192.168.0.1'
)

$ErrorActionPreference = 'SilentlyContinue'

# ─── Logging setup ────────────────────────────────────────────────────────────

$script:SessionId   = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$script:StartTime   = Get-Date
$script:Events      = [System.Collections.Generic.List[hashtable]]::new()

# Local log always available on the WinPE RAM disk
$null = New-Item -ItemType Directory -Path 'X:\Logs' -Force
$script:LogFile = "X:\Logs\winpe-toolkit-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Deploy-share log path populated once the share is accessible
$script:DeployLogFile = $null

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [switch]$NoNewline
    )
    # Screen output (honour colour the same way the old Write-Host calls did)
    if ($NoNewline) {
        Write-Host $Message -ForegroundColor $ForegroundColor -NoNewline
    } else {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }

    # File output
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    if ($script:DeployLogFile) {
        Add-Content -Path $script:DeployLogFile -Value $entry -ErrorAction SilentlyContinue
    }

    # Structured event accumulator (flushed to API later)
    $script:Events.Add(@{
        time    = (Get-Date -Format 'o')
        level   = $Level
        message = $Message
    })
}

function Write-LogSection {
    param([string]$Title)
    $line = "  ── $Title " + ('─' * [Math]::Max(0, 46 - $Title.Length))
    Write-Log ''
    Write-Log $line -ForegroundColor DarkCyan
    $script:Events.Add(@{ time = (Get-Date -Format 'o'); level = 'SECTION'; message = $Title })
}

function Initialize-Session {
    # Collect machine identity for log header and API payload
    $cs  = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bio = Get-WmiObject Win32_BIOS           -ErrorAction SilentlyContinue
    $script:MachineSerial   = $bio.SerialNumber
    $script:MachineHostname = $cs.DNSHostName
    $script:MachineMac      = (Get-NetAdapter -ErrorAction SilentlyContinue |
                                Where-Object Status -eq 'Up' |
                                Select-Object -First 1 -ExpandProperty MacAddress) -replace '-',':'

    $header = @"
================================================================================
  Juniper Design - WinPE Diagnostic Toolkit
  Session : $($script:SessionId)
  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Serial  : $($script:MachineSerial)
  Host    : $($script:MachineHostname)
  MAC     : $($script:MachineMac)
================================================================================
"@
    Add-Content -Path $script:LogFile -Value $header -ErrorAction SilentlyContinue
}

function Open-DeployShareLog {
    # Try to open a mirrored log on the deploy share.
    # Call this after the share is confirmed accessible.
    $logDir = "$DeployShare\logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    $slug  = ($script:MachineMac -replace ':','')
    if (-not $slug) { $slug = $script:SessionId }
    $script:DeployLogFile = "$logDir\winpe-$slug-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    # Seed it with everything logged so far
    if (Test-Path $script:LogFile) {
        Copy-Item $script:LogFile $script:DeployLogFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "  Log mirrored to deploy share: $($script:DeployLogFile)" -ForegroundColor DarkGray
}

function Send-InventoryEvent {
    param([string]$Category = 'winpe_diagnostic')
    # Best-effort POST to inventory API -- never throws, never blocks the user
    try {
        $payload = @{
            event_type = $Category
            session_id = $script:SessionId
            timestamp  = (Get-Date -Format 'o')
            machine    = @{
                serial   = $script:MachineSerial
                hostname = $script:MachineHostname
                mac      = $script:MachineMac
            }
            events = $script:Events.ToArray()
        } | ConvertTo-Json -Depth 5 -Compress

        $null = Invoke-RestMethod `
            -Uri "$InventoryApi/ingest/winpe-event" `
            -Method POST `
            -Body $payload `
            -ContentType 'application/json' `
            -TimeoutSec 5 `
            -ErrorAction Stop

        Write-Log '  Diagnostic log posted to inventory API.' -ForegroundColor DarkGray
    } catch {
        # Not fatal -- log the failure quietly
        Add-Content -Path $script:LogFile `
            -Value "$(Get-Date -Format 'HH:mm:ss') [WARN] Inventory API post failed: $_" `
            -ErrorAction SilentlyContinue
    }
}

# ─── UI helpers ───────────────────────────────────────────────────────────────

function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host '   Juniper Design  -  WinPE Toolkit          ' -ForegroundColor Cyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host "  Session: $($script:SessionId)   Log: X:\Logs\" -ForegroundColor DarkGray
    Write-Host ''
}

function Pause-ForUser {
    Write-Host ''
    Read-Host '  Press Enter to continue'
}

# ─── Diagnostics ──────────────────────────────────────────────────────────────

function Show-NetworkAdapters {
    Write-LogSection 'Network Adapters'
    # USB NICs can take 10-20s to initialize after wpeinit.
    $adapters = $null
    for ($retry = 0; $retry -lt 4; $retry++) {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
        if ($adapters) { break }
        if ($retry -lt 3) {
            Write-Log "  Waiting for NIC to initialize... ($($retry * 5 + 5)s)" -ForegroundColor DarkGray
            Start-Sleep 5
        }
    }
    if (-not $adapters) {
        Write-Log '  !! No network adapters detected after 20s wait.' -ForegroundColor Red -Level 'ERROR'
        Write-Log '' -ForegroundColor Gray
        Write-Log '  This usually means WinPE is missing drivers for your NIC.' -ForegroundColor Yellow -Level 'WARN'
        Write-Log '    - Integrated NIC: check 01c-build-winpe.ps1 for driver injection' -ForegroundColor Yellow
        Write-Log '    - USB-C NIC (Realtek RTL8153 or AX88179): usually inbox' -ForegroundColor Yellow
        Write-Log '    - If still missing: run 09-inject-usb-nic-drivers.ps1 on pc-deploy' -ForegroundColor Yellow
        return
    }
    foreach ($a in $adapters) {
        $color = if ($a.Status -eq 'Up') { 'Green' } elseif ($a.Status -eq 'Disconnected') { 'Red' } else { 'Yellow' }
        $line  = "  [$($a.Status.PadRight(12))] $($a.Name.PadRight(30)) $($a.MacAddress)  $($a.LinkSpeed)"
        Write-Log $line -ForegroundColor $color
    }
    Write-Log ''
    Write-LogSection 'IP Configuration'
    $configs = Get-NetIPConfiguration
    if (-not $configs) {
        Write-Log '  (none)' -ForegroundColor Yellow
        return
    }
    foreach ($c in $configs) {
        $ip  = $c.IPv4Address.IPAddress
        $gw  = $c.IPv4DefaultGateway.NextHop
        $dns = ($c.DNSServer.ServerAddresses -join ', ')
        if ($ip) {
            Write-Log "  $($c.InterfaceAlias) : $ip  GW=$gw  DNS=$dns"
        } else {
            Write-Log "  $($c.InterfaceAlias) : no IP (DHCP not yet assigned or cable unplugged)" -ForegroundColor Yellow
        }
    }
}

function Test-Connectivity {
    Write-LogSection 'Connectivity'
    $tests = @(
        @{ Target = $Router;       Label = "Router        ($Router)" },
        @{ Target = $DeployServer; Label = "Deploy server ($DeployServer)" }
    )
    foreach ($t in $tests) {
        $ok    = Test-Connection $t.Target -Count 2 -Quiet
        $color = if ($ok) { 'Green' } else { 'Red' }
        $level = if ($ok) { 'INFO'  } else { 'WARN' }
        Write-Log "  $($t.Label) : $(if ($ok) { 'REACHABLE' } else { 'UNREACHABLE' })" -ForegroundColor $color -Level $level
    }

    Write-Log ''
    Write-Log '  Port tests on deploy server:'
    foreach ($port in @(69, 445)) {
        $r = Test-NetConnection -ComputerName $DeployServer -Port $port -WarningAction SilentlyContinue
        $label = switch ($port) {
            69  { 'TFTP (UDP 69) - TCP probe only, UDP unreachable is normal' }
            445 { 'SMB  (TCP 445) - must be open for deploy share access' }
        }
        $ok    = $r.TcpTestSucceeded
        $color = if ($port -eq 445) { if ($ok) { 'Green' } else { 'Red' } } else { 'DarkGray' }
        $level = if ($port -eq 445 -and -not $ok) { 'WARN' } else { 'INFO' }
        Write-Log "    Port $port : $(if ($ok) { 'OPEN' } else { 'CLOSED' })  - $label" -ForegroundColor $color -Level $level
    }
}

function Test-DeployShare {
    Write-LogSection 'Deploy Share'
    Write-Log "  Connecting to $DeployShare (15s timeout)..." -ForegroundColor DarkGray
    $job = Start-Job -ScriptBlock {
        param($share)
        net use $share /persistent:no 2>&1
    } -ArgumentList $DeployShare
    $null = Wait-Job $job -Timeout 15
    if ($job.State -eq 'Running') {
        Stop-Job $job
        Write-Log "  $DeployShare : TIMED OUT (SMB blocked or server unreachable)" -ForegroundColor Red -Level 'ERROR'
        Write-Log '' -ForegroundColor Gray
        Write-Log '  Possible causes:' -ForegroundColor Yellow
        Write-Log '    - SMB encryption mismatch on pc-deploy' -ForegroundColor Yellow
        Write-Log '    - Port 445 blocked by firewall' -ForegroundColor Yellow
        Write-Log '    - deploy$ share not created (run 01d-setup-deploy-share.ps1)' -ForegroundColor Yellow
        Remove-Job $job -Force
        return
    }
    Remove-Job $job -Force

    if (Test-Path $DeployShare) {
        Write-Log "  $DeployShare : ACCESSIBLE" -ForegroundColor Green
        Open-DeployShareLog   # mirror log to share now that we can reach it
        Write-Log ''
        Get-ChildItem $DeployShare | ForEach-Object {
            Write-Log "    $($_.Name)"
        }
    } else {
        Write-Log "  $DeployShare : NOT ACCESSIBLE" -ForegroundColor Red -Level 'ERROR'
        Write-Log ''
        Write-Log '  Possible causes:' -ForegroundColor Yellow
        Write-Log '    - SMB encryption mismatch on pc-deploy' -ForegroundColor Yellow
        Write-Log '    - Port 445 blocked by firewall' -ForegroundColor Yellow
        Write-Log '    - deploy$ share not created (run 01d-setup-deploy-share.ps1)' -ForegroundColor Yellow
    }
}

function Show-DhcpDetails {
    Write-LogSection 'DHCP Details'

    $wmiAdapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.DHCPEnabled }
    if (-not $wmiAdapters) {
        Write-Log '  No DHCP-enabled adapters found.' -ForegroundColor Yellow -Level 'WARN'
        return
    }
    foreach ($d in $wmiAdapters) {
        $ip = ($d.IPAddress | Where-Object { $_ -match '\.' }) -join ', '
        if (-not $ip) { continue }
        Write-Log "  Adapter     : $($d.Description)"
        Write-Log "  IP          : $ip"
        Write-Log "  DHCP Server : $($d.DHCPServer)"
        Write-Log "  Gateway     : $(($d.DefaultIPGateway) -join ', ')"
        Write-Log ''
    }

    Write-Log '  DHCP PXE options:'
    $opts66 = $null; $opts67 = $null
    try {
        $allOpts = Get-DhcpClientOptionValue -ErrorAction Stop
        $opts66  = ($allOpts | Where-Object OptionId -eq 66).Value
        $opts67  = ($allOpts | Where-Object OptionId -eq 67).Value
    } catch {}

    if ($opts66) {
        $color = if ($opts66 -eq $DeployServer) { 'Green' } else { 'Yellow' }
        $level = if ($opts66 -eq $DeployServer) { 'INFO'  } else { 'WARN'  }
        Write-Log "    Option 66 (TFTP Server) : $opts66" -ForegroundColor $color -Level $level
        if ($opts66 -ne $DeployServer) {
            Write-Log "      !! Expected $DeployServer - check Ubiquiti DHCP option 66" -ForegroundColor Yellow -Level 'WARN'
        }
    } else {
        Write-Log '    Option 66 (TFTP Server) : NOT RECEIVED' -ForegroundColor Red -Level 'ERROR'
        Write-Log "      Set DHCP option 66 = $DeployServer on the Ubiquiti router." -ForegroundColor Yellow
    }

    if ($opts67) {
        $color = if ($opts67 -match 'bootx64') { 'Green' } else { 'Yellow' }
        $level = if ($opts67 -match 'bootx64') { 'INFO'  } else { 'WARN'  }
        Write-Log "    Option 67 (Boot File)   : $opts67" -ForegroundColor $color -Level $level
        if ($opts67 -notmatch 'bootx64') {
            Write-Log '      !! Expected EFI\Boot\bootx64.efi' -ForegroundColor Yellow -Level 'WARN'
        }
    } else {
        Write-Log '    Option 67 (Boot File)   : NOT RECEIVED' -ForegroundColor Red -Level 'ERROR'
        Write-Log "      Set DHCP option 67 = EFI\Boot\bootx64.efi on the Ubiquiti router." -ForegroundColor Yellow
        Write-Log '      Also verify tftpd64 proxy DHCP is running on pc-deploy.' -ForegroundColor Yellow
    }

    Write-Log ''
    Write-Log '  Full ipconfig /all:'
    $ipcfg = ipconfig /all | Out-String
    # Write to screen raw, and log to file
    Write-Host $ipcfg
    Add-Content -Path $script:LogFile -Value $ipcfg -ErrorAction SilentlyContinue
    if ($script:DeployLogFile) {
        Add-Content -Path $script:DeployLogFile -Value $ipcfg -ErrorAction SilentlyContinue
    }
}

function Show-HardwareInfo {
    Write-LogSection 'Hardware Identity'
    $cs  = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bio = Get-WmiObject Win32_BIOS           -ErrorAction SilentlyContinue
    $cpu = Get-WmiObject Win32_Processor      -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Log "  Manufacturer : $($cs.Manufacturer)"
    Write-Log "  Model        : $($cs.Model)"
    Write-Log "  Serial       : $($bio.SerialNumber)"
    Write-Log "  CPU          : $($cpu.Name)"
    Write-Log "  RAM          : $([math]::Round($cs.TotalPhysicalMemory/1GB, 1)) GB"
    Write-Log ''
    Write-LogSection 'Network Adapters (PCI)'
    # Show PnP network devices so driver issues are visible
    Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | ForEach-Object {
        $status = if ($_.Status -eq 'OK') { 'OK' } else { $_.Status }
        $color  = if ($_.Status -eq 'OK') { 'Green' } else { 'Yellow' }
        Write-Log "  [$status] $($_.FriendlyName)" -ForegroundColor $color
        Write-Log "       DeviceID: $($_.DeviceID)" -ForegroundColor DarkGray
    }
}

function Run-FullDiagnostic {
    Show-NetworkAdapters
    Test-Connectivity
    Test-DeployShare
    Show-DhcpDetails
    Show-HardwareInfo

    # Attempt to flush events to inventory API
    Write-Log ''
    Write-Log '  Sending diagnostic report to inventory API...' -ForegroundColor DarkGray
    Send-InventoryEvent -Category 'winpe_full_diagnostic'
    Write-Log "  Local log saved: X:\Logs\$(Split-Path $script:LogFile -Leaf)" -ForegroundColor DarkGray
}

function Show-Help {
    Write-LogSection 'Help - PXE Troubleshooting Notes'
    Write-Log ''
    Write-Log '  PXE boot flow:' -ForegroundColor DarkGray
    Write-Log '    1. Machine broadcasts DHCP discover with PXEClient tag'
    Write-Log '    2. DHCP server replies with IP + option 66 (TFTP IP) + option 67 (boot file)'
    Write-Log '    3. tftpd64 proxy DHCP on pc-deploy intercepts and supplies options 66/67'
    Write-Log '    4. Machine TFTP-downloads wdsmgfw_EX.efi from pc-deploy'
    Write-Log '    5. EFI loader chainloads boot.wim (WinPE)'
    Write-Log ''
    Write-Log '  NIC not detected in WinPE:' -ForegroundColor DarkGray
    Write-Log '    - Use [6] Hardware Info to see the PCI DeviceID of the NIC'
    Write-Log '    - Cross-check DeviceID against drivers injected in boot.wim'
    Write-Log '    - Run 01c-build-winpe.ps1 on pc-deploy to rebuild WIM with correct drivers'
    Write-Log ''
    Write-Log '  USB NIC issues:' -ForegroundColor DarkGray
    Write-Log '    - USB/Thunderbolt NICs rarely have a PXE ROM -- use this USB boot instead'
    Write-Log '    - If NIC shows Up but no IP: cable connected after POST? replug it'
    Write-Log ''
    Write-Log '  DHCP option 66/67 not received:' -ForegroundColor DarkGray
    Write-Log "    - tftpd64 service not running on pc-deploy"
    Write-Log "    - Ubiquiti option 66 not set to $DeployServer"
    Write-Log '    - Ubiquiti option 67 not set to EFI\Boot\bootx64.efi'
}

# ─── Main loop ────────────────────────────────────────────────────────────────

# Ensure wpeinit has run (network stack needs to be up)
$earlyAdapters = Get-NetAdapter -ErrorAction SilentlyContinue
if (-not $earlyAdapters) {
    Write-Host '  Running wpeinit to initialize network stack...' -ForegroundColor Yellow
    wpeinit
    Start-Sleep 4
}

Initialize-Session

while ($true) {
    Write-Banner
    Write-Host '  Select a diagnostic:' -ForegroundColor Yellow
    Write-Host '    [1] Network adapters and IP config'
    Write-Host '    [2] Connectivity tests (ping + port checks)'
    Write-Host '    [3] Deploy share access test'
    Write-Host '    [4] DHCP details + PXE options 66/67'
    Write-Host '    [5] Full diagnostic (all of the above)'
    Write-Host '    [6] Hardware info + PCI device IDs'
    Write-Host '    [H] Help / PXE troubleshooting notes'
    Write-Host '    [L] Show log file path + flush to API'
    Write-Host '    [D] Launch deploy script'
    Write-Host '    [R] Reboot'
    Write-Host ''

    $choice = (Read-Host '  Choice').Trim().ToUpper()

    switch ($choice) {
        '1' { Show-NetworkAdapters;  Pause-ForUser }
        '2' { Test-Connectivity;     Pause-ForUser }
        '3' { Test-DeployShare;      Pause-ForUser }
        '4' { Show-DhcpDetails;      Pause-ForUser }
        '5' { Run-FullDiagnostic;    Pause-ForUser }
        '6' { Show-HardwareInfo;     Pause-ForUser }
        'H' { Show-Help;             Pause-ForUser }
        'L' {
            Write-Log ''
            Write-Log "  Local log  : $($script:LogFile)" -ForegroundColor Cyan
            if ($script:DeployLogFile) {
                Write-Log "  Share log  : $($script:DeployLogFile)" -ForegroundColor Cyan
            }
            Write-Log "  Events     : $($script:Events.Count) logged this session" -ForegroundColor Cyan
            Write-Log '  Flushing to inventory API...' -ForegroundColor DarkGray
            Send-InventoryEvent -Category 'winpe_manual_flush'
            Pause-ForUser
        }
        'D' {
            Write-Log '  Launching deploy-boot.ps1...' -ForegroundColor Green
            & X:\Windows\System32\deploy-boot.ps1
            break
        }
        'R' {
            Write-Log '  Rebooting...' -ForegroundColor Yellow
            Send-InventoryEvent -Category 'winpe_session_end'
            Start-Sleep 2
            wpeutil reboot
            exit
        }
        default { Write-Host '  Invalid choice.' -ForegroundColor Yellow; Start-Sleep 1 }
    }
}
