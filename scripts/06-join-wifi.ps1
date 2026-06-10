# 06-join-wifi.ps1
# Joins the target PC to the office Wi-Fi network using a profile exported
# from an already-connected PC, or by creating a new profile from 1Password.
#
# The PSK is NEVER stored in this script. It is read at runtime from 1Password
# using 'op read' - the 1Password CLI must be signed in first.
#
# USAGE: .\06-join-wifi.ps1
#        .\06-join-wifi.ps1 -Ssid "JuniperOffice" -OpItem "WiFi/Office"

param(
    # SSID to connect to
    [string]$Ssid = 'JuniperOffice',

    # 1Password item path for the Wi-Fi PSK
    # Format: "Vault/Item" or just "Item" for the default vault
    [string]$OpItem = 'WiFi/Office PSK',

    # Path to an existing exported .xml profile (alternative to 1Password)
    [string]$ProfileXml = '',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Check if already connected ----------------------------------------------
$current = (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' } |
            Select-Object -First 1).Name

if ($current -eq $Ssid) {
    Write-Host "Already connected to '$Ssid'." -ForegroundColor Green
    exit 0
}

Write-Host "==> Joining Wi-Fi: $Ssid" -ForegroundColor Cyan

if ($ProfileXml -and (Test-Path $ProfileXml)) {
    # --- Option A: import an existing exported profile -----------------------
    Write-Host "  Using profile XML: $ProfileXml" -ForegroundColor Cyan
    if (-not $DryRun) {
        netsh wlan add profile filename="$ProfileXml" user=all
        netsh wlan connect name="$Ssid"
    }
} else {
    # --- Option B: build profile from 1Password PSK --------------------------
    Write-Host "  Reading PSK from 1Password ($OpItem)..." -ForegroundColor Cyan

    $op = Get-Command op -ErrorAction SilentlyContinue
    if (-not $op) {
        Write-Host 'ERROR: 1Password CLI (op) not found. Install it from https://1password.com/downloads/command-line/' -ForegroundColor Red
        exit 1
    }

    if (-not $DryRun) {
        $psk = & op read "op://$OpItem/password" 2>$null
        if (-not $psk) {
            Write-Host "ERROR: Could not read PSK from 1Password. Sign in with 'op signin' first." -ForegroundColor Red
            exit 1
        }

        # Build a minimal WPA2-Personal profile XML
        $profileXmlContent = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$Ssid</name>
  <SSIDConfig><SSID><name>$Ssid</name></SSID></SSIDConfig>
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
        $tmpXml = [IO.Path]::GetTempFileName() -replace '\.tmp$', '.xml'
        $profileXmlContent | Out-File $tmpXml -Encoding UTF8
        netsh wlan add profile filename="$tmpXml" user=all
        Remove-Item $tmpXml -Force   # scrub PSK from disk immediately
        netsh wlan connect name="$Ssid"
    }
}

if (-not $DryRun) {
    Start-Sleep 5
    $after = (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
              Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' } |
              Select-Object -First 1).Name
    if ($after -eq $Ssid) {
        Write-Host "  Connected to '$Ssid'." -ForegroundColor Green
    } else {
        Write-Host "  WARN: Connection attempted but not yet confirmed. Check Wi-Fi status manually." -ForegroundColor Yellow
    }
}

if ($DryRun) { Write-Host '(Dry run - no changes made.)' -ForegroundColor Yellow }
