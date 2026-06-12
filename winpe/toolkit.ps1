# toolkit.ps1 — Juniper Design WinPE Diagnostic Toolkit
#
# Baked into WinPE at X:\Windows\System32\toolkit.ps1
# Launched by deploy-boot.ps1 when T is pressed at startup.
#
# Helps diagnose PXE / network issues on machines without an integrated NIC
# (USB-C adapters, Thunderbolt docks, etc.)

param(
    [string]$DeployServer = '192.168.5.141',
    [string]$DeployShare  = '\\192.168.5.141\deploy$',
    [string]$Router       = '192.168.0.1'
)

$ErrorActionPreference = 'SilentlyContinue'

# - Helpers -

function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host '   Juniper Design  -  WinPE Toolkit          ' -ForegroundColor Cyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "  - $Title " -ForegroundColor DarkCyan
}

function Pause-ForUser {
    Write-Host ''
    Read-Host '  Press Enter to continue'
}

# - Diagnostics -

function Show-NetworkAdapters {
    Write-Section 'Network Adapters'
    # USB NICs (ASIX AX88179, Realtek RTL8153) can take 10-20s to initialize after wpeinit.
    # Retry up to 20 seconds before declaring no adapter found.
    $adapters = $null
    for ($retry = 0; $retry -lt 4; $retry++) {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
        if ($adapters) { break }
        if ($retry -lt 3) {
            Write-Host "  Waiting for NIC to initialize... ($($retry * 5 + 5)s)" -ForegroundColor DarkGray
            Start-Sleep 5
        }
    }
    if (-not $adapters) {
        Write-Host '  !! No network adapters detected after 20s wait.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  This usually means WinPE is missing drivers for your USB or' -ForegroundColor Yellow
        Write-Host '  Thunderbolt NIC. Common chips and what to try:' -ForegroundColor Yellow
        Write-Host '    - Lenovo USB-C NIC : likely Realtek RTL8153 (usually inbox)' -ForegroundColor Yellow
        Write-Host '    - Baseus dock      : likely Realtek RTL8153 or AX88179' -ForegroundColor Yellow
        Write-Host '    - If still missing : run 09-inject-usb-nic-drivers.ps1 on' -ForegroundColor Yellow
        Write-Host '      pc-deploy to add USB NIC drivers to the WinPE image.' -ForegroundColor Yellow
        return
    }
    foreach ($a in $adapters) {
        $color = if ($a.Status -eq 'Up') { 'Green' } elseif ($a.Status -eq 'Disconnected') { 'Red' } else { 'Yellow' }
        Write-Host "  [$($a.Status.PadRight(12))] $($a.Name.PadRight(30)) $($a.MacAddress)  $($a.LinkSpeed)" -ForegroundColor $color
    }
    Write-Host ''
    Write-Host '  - IP Configuration'
    $configs = Get-NetIPConfiguration
    if (-not $configs) {
        Write-Host '  (none)' -ForegroundColor Yellow
        return
    }
    foreach ($c in $configs) {
        $ip  = $c.IPv4Address.IPAddress
        $gw  = $c.IPv4DefaultGateway.NextHop
        $dns = ($c.DNSServer.ServerAddresses -join ', ')
        if ($ip) {
            Write-Host "  $($c.InterfaceAlias) : $ip  GW=$gw  DNS=$dns"
        } else {
            Write-Host "  $($c.InterfaceAlias) : no IP (DHCP not yet assigned or cable unplugged)" -ForegroundColor Yellow
        }
    }
}

function Test-Connectivity {
    Write-Section 'Connectivity'
    $tests = @(
        @{ Target = $Router;       Label = "Router        ($Router)" },
        @{ Target = $DeployServer; Label = "Deploy server ($DeployServer)" }
    )
    foreach ($t in $tests) {
        $ok    = Test-Connection $t.Target -Count 2 -Quiet
        $color = if ($ok) { 'Green' } else { 'Red' }
        Write-Host "  $($t.Label) : $(if ($ok) { 'REACHABLE' } else { 'UNREACHABLE' })" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '  Port tests on deploy server:'
    foreach ($port in @(69, 445)) {
        $r = Test-NetConnection -ComputerName $DeployServer -Port $port -WarningAction SilentlyContinue
        $label = switch ($port) {
            69  { 'TFTP (UDP 69) — TCP probe only, UDP unreachable is normal' }
            445 { 'SMB  (TCP 445) — must be open for deploy share access' }
        }
        $ok    = $r.TcpTestSucceeded
        $color = if ($port -eq 445) { if ($ok) { 'Green' } else { 'Red' } } else { 'DarkGray' }
        Write-Host "    Port $port : $(if ($ok) { 'OPEN' } else { 'CLOSED' })  — $label" -ForegroundColor $color
    }
}

function Test-DeployShare {
    Write-Section 'Deploy Share'
    # net use can hang for minutes if SMB is blocked -- run it as a job with a 15s timeout
    Write-Host "  Connecting to $DeployShare (15s timeout)..." -ForegroundColor DarkGray
    $job = Start-Job -ScriptBlock {
        param($share)
        net use $share /persistent:no 2>&1
    } -ArgumentList $DeployShare
    $null = Wait-Job $job -Timeout 15
    if ($job.State -eq 'Running') {
        Stop-Job $job
        Write-Host "  $DeployShare : TIMED OUT (SMB blocked or server unreachable)" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Possible causes:' -ForegroundColor Yellow
        Write-Host '    - SMB encryption required on pc-deploy (run: Set-SmbServerConfiguration -RejectUnencryptedAccess $false -Force)' -ForegroundColor Yellow
        Write-Host '    - Port 445 blocked by firewall' -ForegroundColor Yellow
        Write-Host '    - deploy$ share not created (run 01d-setup-deploy-share.ps1)' -ForegroundColor Yellow
        Remove-Job $job -Force
        return
    }
    Remove-Job $job -Force

    if (Test-Path $DeployShare) {
        Write-Host "  $DeployShare : ACCESSIBLE" -ForegroundColor Green
        Write-Host ''
        Get-ChildItem $DeployShare | ForEach-Object {
            Write-Host "    $($_.Name)"
        }
    } else {
        Write-Host "  $DeployShare : NOT ACCESSIBLE" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Possible causes:' -ForegroundColor Yellow
        Write-Host '    - SMB encryption required on pc-deploy (run: Set-SmbServerConfiguration -RejectUnencryptedAccess $false -Force)' -ForegroundColor Yellow
        Write-Host '    - Port 445 blocked by firewall' -ForegroundColor Yellow
        Write-Host '    - deploy$ share not created (run 01d-setup-deploy-share.ps1)' -ForegroundColor Yellow
    }
}

function Show-DhcpDetails {
    Write-Section 'DHCP Details'

    $wmiAdapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.DHCPEnabled }
    if (-not $wmiAdapters) {
        Write-Host '  No DHCP-enabled adapters found.' -ForegroundColor Yellow
        return
    }
    foreach ($d in $wmiAdapters) {
        $ip = ($d.IPAddress | Where-Object { $_ -match '\.' }) -join ', '
        if (-not $ip) { continue }
        Write-Host "  Adapter     : $($d.Description)"
        Write-Host "  IP          : $ip"
        Write-Host "  DHCP Server : $($d.DHCPServer)"
        Write-Host "  Gateway     : $(($d.DefaultIPGateway) -join ', ')"
        Write-Host ''
    }

    # Try to read DHCP options 66 (TFTP server) and 67 (boot file)
    Write-Host '  DHCP PXE options:'
    $opts66 = $null; $opts67 = $null
    try {
        $allOpts = Get-DhcpClientOptionValue -ErrorAction Stop
        $opts66  = ($allOpts | Where-Object OptionId -eq 66).Value
        $opts67  = ($allOpts | Where-Object OptionId -eq 67).Value
    } catch {}

    if ($opts66) {
        $color = if ($opts66 -eq $DeployServer) { 'Green' } else { 'Yellow' }
        Write-Host "    Option 66 (TFTP Server) : $opts66" -ForegroundColor $color
        if ($opts66 -ne $DeployServer) {
            Write-Host "      !! Expected $DeployServer — check Ubiquiti DHCP option 66" -ForegroundColor Yellow
        }
    } else {
        Write-Host '    Option 66 (TFTP Server) : NOT RECEIVED' -ForegroundColor Red
        Write-Host "      Set DHCP option 66 = $DeployServer on the Ubiquiti router." -ForegroundColor Yellow
    }

    if ($opts67) {
        $color = if ($opts67 -match 'bootx64') { 'Green' } else { 'Yellow' }
        Write-Host "    Option 67 (Boot File)   : $opts67" -ForegroundColor $color
        if ($opts67 -notmatch 'bootx64') {
            Write-Host "      !! Expected EFI\Boot\bootx64.efi" -ForegroundColor Yellow
        }
    } else {
        Write-Host '    Option 67 (Boot File)   : NOT RECEIVED' -ForegroundColor Red
        Write-Host "      Set DHCP option 67 = EFI\Boot\bootx64.efi on the Ubiquiti router." -ForegroundColor Yellow
        Write-Host '      Also verify tftpd64 proxy DHCP is running on pc-deploy.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  Full ipconfig /all:'
    ipconfig /all
}

function Run-FullDiagnostic {
    Show-NetworkAdapters
    Test-Connectivity
    Test-DeployShare
    Show-DhcpDetails
}

function Show-Help {
    Write-Section 'Help — PXE Troubleshooting Notes'
    Write-Host ''
    Write-Host '  PXE boot flow:' -ForegroundColor DarkGray
    Write-Host '    1. Machine broadcasts DHCP discover with PXEClient tag'
    Write-Host '    2. DHCP server replies with IP + option 66 (TFTP IP) + option 67 (boot file)'
    Write-Host '    3. tftpd64 proxy DHCP on pc-deploy intercepts and supplies options 66/67'
    Write-Host '    4. Machine TFTP-downloads EFI\Boot\bootx64.efi from pc-deploy'
    Write-Host '    5. bootx64.efi chainloads boot.wim (WinPE)'
    Write-Host ''
    Write-Host '  USB NIC PXE issues:' -ForegroundColor DarkGray
    Write-Host '    - USB/Thunderbolt NICs rarely have a PXE ROM — use this USB instead'
    Write-Host '    - If this NIC shows Up but no IP: cable connected after POST? replug it'
    Write-Host '    - If NIC not detected: WinPE missing drivers — see 01c-build-winpe.ps1'
    Write-Host ''
    Write-Host '  DHCP option 66/67 not received:' -ForegroundColor DarkGray
    Write-Host '    - tftpd64 service not running on pc-deploy (check task 2 above)'
    Write-Host "    - Ubiquiti option 66 not set to $DeployServer"
    Write-Host '    - Ubiquiti option 67 not set to EFI\Boot\bootx64.efi'
}

# - Main loop -

Write-Banner

# Ensure wpeinit has run (network stack needs to be up)
$adapters = Get-NetAdapter
if (-not $adapters) {
    Write-Host '  Running wpeinit to initialize network stack...' -ForegroundColor Yellow
    wpeinit
    Start-Sleep 4
}

while ($true) {
    Write-Banner
    Write-Host '  Select a diagnostic:' -ForegroundColor Yellow
    Write-Host '    [1] Network adapters and IP config'
    Write-Host '    [2] Connectivity tests (ping + port checks)'
    Write-Host '    [3] Deploy share access test'
    Write-Host '    [4] DHCP details + PXE options 66/67'
    Write-Host '    [5] Full diagnostic (all of the above)'
    Write-Host '    [H] Help / PXE troubleshooting notes'
    Write-Host '    [D] Launch deploy script'
    Write-Host '    [R] Reboot'
    Write-Host ''

    $choice = (Read-Host '  Choice').Trim().ToUpper()

    switch ($choice) {
        '1' { Show-NetworkAdapters;    Pause-ForUser }
        '2' { Test-Connectivity;       Pause-ForUser }
        '3' { Test-DeployShare;        Pause-ForUser }
        '4' { Show-DhcpDetails;        Pause-ForUser }
        '5' { Run-FullDiagnostic;      Pause-ForUser }
        'H' { Show-Help;               Pause-ForUser }
        'D' {
            Write-Host '  Launching deploy-boot.ps1...' -ForegroundColor Green
            & X:\Windows\System32\deploy-boot.ps1
            break
        }
        'R' {
            Write-Host '  Rebooting...' -ForegroundColor Yellow
            Start-Sleep 2
            wpeutil reboot
            exit
        }
        default { Write-Host '  Invalid choice.' -ForegroundColor Yellow; Start-Sleep 1 }
    }
}
