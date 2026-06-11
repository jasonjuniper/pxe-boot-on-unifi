# store-unifi-creds.ps1
# Run this ONCE from an interactive PowerShell terminal (not via Claude/MCP).
# Reads UniFi credentials from 1Password, stores them DPAPI-encrypted at
#   C:\Users\ENG2\.juniper-unifi.xml
# then sets UNIFI_* env vars in the JuniperInventory service on pc-deploy
# and restarts the service.
#
# After it completes you will never need 1Password for this again.
#
# USAGE (from an admin PS terminal on ENG-2):
#   .\store-unifi-creds.ps1

$ErrorActionPreference = 'Stop'

$opExe    = 'C:\Users\ENG2\AppData\Local\Microsoft\WinGet\Packages\AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\op.exe'
$dpapiOut = 'C:\Users\ENG2\.juniper-unifi.xml'

# ── Read from 1Password ────────────────────────────────────────────────────────
Write-Host "Reading UniFi credentials from 1Password..." -ForegroundColor Cyan

# Try both common field names for host
$unifiHost = & $opExe read "op://Private/unifi-controller/hostname" 2>$null
if (-not $unifiHost) { $unifiHost = & $opExe read "op://Private/unifi-controller/host" 2>$null }
if (-not $unifiHost) { $unifiHost = & $opExe read "op://Private/unifi-controller/url"  2>$null }

$unifiUser = & $opExe read "op://Private/unifi-controller/username" 2>$null
$unifiPw   = & $opExe read "op://Private/unifi-controller/password" 2>$null

if (-not $unifiHost -or -not $unifiUser -or -not $unifiPw) {
    Write-Host ""
    Write-Host "Could not read one or more fields. Listing available fields:" -ForegroundColor Yellow
    & $opExe item get "unifi-controller" --vault Private --format json |
        ConvertFrom-Json | Select-Object -ExpandProperty fields |
        Select-Object label, id | Format-Table -AutoSize
    Write-Host ""
    Write-Host "Edit the op://Private/unifi-controller/... paths in this script to match." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Got host:     $unifiHost" -ForegroundColor Green
Write-Host "  Got username: $unifiUser" -ForegroundColor Green
Write-Host "  Got password: [hidden]"   -ForegroundColor Green

# ── Store DPAPI-encrypted ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "Saving to $dpapiOut ..." -ForegroundColor Cyan

$payload      = @{ host = $unifiHost; username = $unifiUser; password = $unifiPw } | ConvertTo-Json -Compress
$securePay    = ConvertTo-SecureString $payload -AsPlainText -Force
$credObj      = [PSCredential]::new("unifi-credentials", $securePay)
$credObj | Export-Clixml $dpapiOut
Write-Host "  Saved (DPAPI-encrypted, readable only by this Windows account)." -ForegroundColor Green

# ── Update JuniperInventory service on pc-deploy via WinRM ────────────────────
Write-Host ""
Write-Host "Connecting to pc-deploy (192.168.5.141) via WinRM..." -ForegroundColor Cyan

$sess = New-PSSession -ComputerName 192.168.5.141 -Authentication Negotiate

Invoke-Command -Session $sess -ArgumentList $unifiHost, $unifiUser, $unifiPw -ScriptBlock {
    param($h, $u, $p)

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\JuniperInventory'

    # Read existing null-delimited env block
    $existing = (Get-ItemProperty -Path $regPath -Name Environment -ErrorAction SilentlyContinue).Environment
    $envVars  = [ordered]@{}
    if ($existing) {
        ($existing -split "`0") | Where-Object { $_ -match '=' } | ForEach-Object {
            $k, $v = $_ -split '=', 2
            $envVars[$k] = $v
        }
    }

    # Upsert UniFi values
    $envVars['UNIFI_HOST']     = $h
    $envVars['UNIFI_USERNAME'] = $u
    $envVars['UNIFI_PASSWORD'] = $p

    $newEnv = (($envVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`0") + "`0"
    Set-ItemProperty -Path $regPath -Name Environment -Value $newEnv -Force

    Write-Output "Service env vars updated ($(($envVars.Keys -join ', ')))."

    Restart-Service JuniperInventory -Force
    Start-Sleep 6
    $svc = Get-Service JuniperInventory -ErrorAction SilentlyContinue
    Write-Output "JuniperInventory: $($svc.Status)"
}

Remove-PSSession $sess

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "UniFi credentials stored in Credential Manager and injected into service." -ForegroundColor Green
Write-Host "To read them in future scripts (no 1Password needed):" -ForegroundColor DarkGray
Write-Host '  $c = Import-Clixml "C:\Users\ENG2\.juniper-unifi.xml"' -ForegroundColor DarkGray
Write-Host '  $d = $c.GetNetworkCredential().Password | ConvertFrom-Json' -ForegroundColor DarkGray
Write-Host '  # $d.host, $d.username, $d.password' -ForegroundColor DarkGray
Write-Host ""

# Self-delete
Remove-Item $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
