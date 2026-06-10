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
Write-Host '    Firewall rules updated.' -ForegroundColor Green

Write-Host ''
Write-Host '==> Remote access ready.' -ForegroundColor Green
Write-Host "    WinRM port 5985 is open."
Write-Host "    From ENG-2 (run as admin):"
Write-Host "      Test-NetConnection -ComputerName $($env:COMPUTERNAME) -Port 5985"
Write-Host "      `$s = New-PSSession -ComputerName $($env:COMPUTERNAME) -Credential (Get-Credential)"
Write-Host "      Copy-Item -Path .\scripts\* -Destination \\$($env:COMPUTERNAME)\deploy$\scripts\ -Recurse"
