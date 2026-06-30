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

# Wi-Fi join is BEST-EFFORT during imaging: a desktop with no wireless NIC, an
# unreachable inventory API, or a failed association must NEVER abort the image.
# The orchestrator treats any non-zero exit as a (logged) non-fatal error, but we
# additionally trap here and exit 0 so this phase is always green when it is not a
# real problem (no adapter / no creds / join didn't confirm).
trap {
    Write-Host "WARN: Wi-Fi join hit a non-fatal error: $_" -ForegroundColor Yellow
    exit 0
}

# --- No wireless adapter? Skip cleanly (e.g. desktops) -----------------------
$wifiNic = Get-NetAdapter -ErrorAction SilentlyContinue |
           Where-Object { $_.PhysicalMediaType -match 'Native 802.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' }
if (-not $wifiNic) {
    Write-Host "No wireless adapter present - skipping Wi-Fi join (not an error)." -ForegroundColor Yellow
    exit 0
}

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
            Write-Host "WARN: Could not reach inventory Wi-Fi API ($InventoryUrl): $_" -ForegroundColor Yellow
            Write-Host "  Set C:\inventory\wifi.json on pc-deploy and ensure the server is reachable." -ForegroundColor Yellow
            exit 0   # best-effort: never abort imaging
        }

        $ssid = $creds.ssid
        $psk  = $creds.psk
        if (-not $ssid -or -not $psk) {
            Write-Host "WARN: Inventory API returned empty SSID or PSK. Check C:\inventory\wifi.json on pc-deploy." -ForegroundColor Yellow
            exit 0   # best-effort: never abort imaging
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

# Always succeed - Wi-Fi join is best-effort and must not block imaging.
exit 0
