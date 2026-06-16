# 06-join-wifi.ps1
# Joins the target PC to the office Wi-Fi network.
#
# Wi-Fi credentials are fetched from the inventory server's
# /api/management/wifi endpoint - no 1Password CLI required.
#
# To configure: set C:\inventory\wifi.json on pc-deploy with:
#   {"ssid": "YourSSID", "psk": "YourPassphrase"}
#
# Alternatively, pass -ProfileXml to import a pre-exported profile.
#
# USAGE: .\06-join-wifi.ps1
#        .\06-join-wifi.ps1 -ProfileXml \\pc-deploy\deploy$\config\wifi.xml

param(
    # Path to an existing exported .xml profile (skips API lookup)
    [string]$ProfileXml = '',

    # Inventory server base URL
    [string]$InventoryUrl = 'http://inventory.juniperdesign.local:8080',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Check if already connected ----------------------------------------------
$current = (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' } |
            Select-Object -First 1).Name

if ($ProfileXml -and (Test-Path $ProfileXml)) {
    # Option A: import an existing exported profile
    Write-Host "==> Wi-Fi: importing profile from $ProfileXml" -ForegroundColor Cyan
    if (-not $DryRun) {
        netsh wlan add profile filename="$ProfileXml" user=all
        netsh wlan connect name=(([xml](Get-Content $ProfileXml)).WLANProfile.name)
    }
} else {
    # Option B: fetch credentials from inventory server bootstrap API
    Write-Host "==> Wi-Fi: fetching credentials from inventory server..." -ForegroundColor Cyan

    if (-not $DryRun) {
        try {
            $creds = Invoke-RestMethod "$InventoryUrl/api/management/wifi" -TimeoutSec 10 -ErrorAction Stop
        } catch {
            Write-Host "ERROR: Could not reach inventory API ($InventoryUrl): $_" -ForegroundColor Red
            Write-Host "  Set C:\inventory\wifi.json on pc-deploy and ensure the server is reachable." -ForegroundColor Yellow
            exit 1
        }

        $ssid = $creds.ssid
        $psk  = $creds.psk
        if (-not $ssid -or -not $psk) {
            Write-Host "ERROR: Inventory API returned empty SSID or PSK. Check C:\inventory\wifi.json on pc-deploy." -ForegroundColor Red
            exit 1
        }

        if ($current -eq $ssid) {
            Write-Host "Already connected to '$ssid'." -ForegroundColor Green
            $psk = $null; $creds = $null
            exit 0
        }

        # Build a minimal WPA2-Personal profile XML
        $profileXmlContent = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssid</name>
  <SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$psk</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
        $psk = $null; $creds = $null   # clear from memory

        $tmpXml = [IO.Path]::GetTempFileName() -replace '\.tmp$', '.xml'
        $profileXmlContent | Out-File $tmpXml -Encoding UTF8
        netsh wlan add profile filename="$tmpXml" user=all
        Remove-Item $tmpXml -Force      # remove PSK from disk immediately
        netsh wlan connect name="$ssid"
    } else {
        Write-Host "(Dry run - would fetch from $InventoryUrl/api/management/wifi)" -ForegroundColor Yellow
        exit 0
    }
}

if (-not $DryRun) {
    Start-Sleep 5
    $after = (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
              Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' } |
              Select-Object -First 1).Name
    if ($after) {
        Write-Host "  Connected to '$after'." -ForegroundColor Green
    } else {
        Write-Host "  WARN: Connection attempted but not yet confirmed. Check Wi-Fi status manually." -ForegroundColor Yellow
    }
}
