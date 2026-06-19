# 01a-enable-remote-access.ps1
# Enables WinRM, admin shares, and SMB so ENG-2 can manage this machine remotely.
# Run as Administrator on pc-deploy.
#
# This is a standalone prerequisite - run it immediately after renaming the server.
# It does NOT depend on WDS or any other role being installed.
#
# USAGE: .\01a-enable-remote-access.ps1

$ErrorActionPreference = 'Stop'

# Auto-elevate if not running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Not running as Administrator - relaunching elevated...' -ForegroundColor Yellow
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait
    exit
}

Write-Host '==> Enabling remote management on' $env:COMPUTERNAME -ForegroundColor Cyan

# 1. WinRM (PowerShell Remoting) - lets ENG-2 use Invoke-Command / Copy-Item -ToSession
Write-Host '    Starting WinRM...'
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
Set-Service -Name WinRM -StartupType Automatic
Write-Host '    WinRM enabled.' -ForegroundColor Green

# 2. Allow local accounts to reach admin shares (C$) over the network.
#    Windows 10/11 blocks this by default via UAC token filtering.
Write-Host '    Enabling local-account admin share access...'
$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $regPath -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord -Force
Write-Host '    LocalAccountTokenFilterPolicy = 1.' -ForegroundColor Green

# 3. Create C:\deploy and share it as deploy$ (scripts, packages, unattend XMLs go here)
Write-Host '    Creating deploy$ share...'
$deployPath = 'C:\deploy'
New-Item -Path $deployPath -ItemType Directory -Force | Out-Null
$existing = Get-SmbShare -Name 'deploy$' -ErrorAction SilentlyContinue
if (-not $existing) {
    New-SmbShare -Name 'deploy$' -Path $deployPath -FullAccess 'Administrators' | Out-Null
}
Write-Host "    \\$($env:COMPUTERNAME)\deploy$ -> $deployPath" -ForegroundColor Green

# 4. Open WinRM and SMB through the firewall
Write-Host '    Opening firewall ports...'
Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
# Built-in SMB-In rules default to RemoteAddress=LocalSubnet, which only allows the
# interface's immediate subnet.  On a flat /20 network clients on other octets
# (e.g. 192.168.10.x vs 192.168.5.141) are silently blocked even though they're on
# the same LAN.  Set RemoteAddress=Any -- safe for an internal network with no VLANs.
Get-NetFirewallRule -DisplayName 'File and Printer Sharing (SMB-In)' |
    ForEach-Object { $_ | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress Any }
Get-NetFirewallRule -DisplayName 'File and Printer Sharing (Restrictive) (SMB-In)' -ErrorAction SilentlyContinue |
    ForEach-Object { $_ | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress Any }
Write-Host '    Firewall rules updated (SMB open to entire LAN).' -ForegroundColor Green

# 5. Allow unencrypted SMB access so WinPE clients can reach deploy$
#    WinPE's net.exe does not negotiate SMB encryption; RejectUnencryptedAccess=True
#    causes the connection to hang silently until timeout.
Write-Host '    Allowing unencrypted SMB (required for WinPE clients)...'
Set-SmbServerConfiguration -RejectUnencryptedAccess $false -Force
Grant-SmbShareAccess -Name 'deploy$' -AccountName 'Everyone' -AccessRight Read -Force | Out-Null
Write-Host '    SMB unencrypted access enabled; Everyone:Read on deploy$.' -ForegroundColor Green

# 6. Ensure null-session is NOT enabled (WinPE authenticates with baked credentials).
#    Tighten the registry in case it was ever set to allow null sessions.
Write-Host '    Enforcing null-session block (WinPE uses baked junadmin credentials)...'
$lmParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
Set-ItemProperty -Path $lmParams -Name 'NullSessionShares'       -Value @()  -Type MultiString -Force
Set-ItemProperty -Path $lmParams -Name 'RestrictNullSessAccess'  -Value 1    -Type DWord       -Force
Write-Host '    Null-session restricted.' -ForegroundColor Green

# 7. Grant junadmin Read access to deploy$ share and NTFS folder.
#    WinPE connects as junadmin -- credentials are baked into the WIM at build time
#    by running scripts\wim-bake-credentials.ps1 from ENG-2.
Write-Host '    Granting junadmin Read on deploy$...'
Grant-SmbShareAccess -Name 'deploy$' -AccountName 'junadmin' -AccessRight Read -Force | Out-Null
$acl  = Get-Acl 'C:\deploy'
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'junadmin', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl 'C:\deploy' $acl
Write-Host '    junadmin:Read on deploy$.' -ForegroundColor Green

Write-Host ''
Write-Host '==> Remote access ready.' -ForegroundColor Green
Write-Host "    WinRM port 5985 is open."
Write-Host "    From ENG-2 (run as admin):"
Write-Host "      Test-NetConnection -ComputerName $($env:COMPUTERNAME) -Port 5985"
Write-Host "      `$s = New-PSSession -ComputerName $($env:COMPUTERNAME) -Credential (Get-Credential)"
Write-Host "      Copy-Item -Path .\scripts\* -Destination \\$($env:COMPUTERNAME)\deploy$\scripts\ -Recurse"
