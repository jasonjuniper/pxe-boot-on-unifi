# ensure-critical.ps1  -  Juniper Imaging CRITICAL-phase safety net
#
# Guarantees the two USER-FACING critical steps fire even if the main
# orchestrator collapses, strands, or times out before reaching them:
#     * join-wifi  (06-join-wifi.ps1)
#     * setup-user (10-setup-user.ps1)
#
# Registered at Bootstrap as its OWN scheduled task (`JuniperEnsureCritical`,
# SYSTEM, AtStartup + 5-min repetition for 1h) so it has a lifecycle INDEPENDENT
# of `JuniperImaging`. The orchestrator's teardown removes JuniperImaging but
# NOT this task, so this still runs on the final clean boot. On each fire it:
#
#   1. DEFERS if the orchestrator is actively running (JuniperImaging = Running)
#      - the normal path will do these phases itself; no double-run.
#   2. Otherwise (orchestrator done, removed, crashed, or stranded) it
#      SANITY-CHECKS the live state of each critical:
#        - Wi-Fi:  no wireless adapter -> N/A (satisfied); already connected ->
#          satisfied (+ set profile Private); else re-run 06-join-wifi.ps1.
#        - User:   a local_<name> account already exists -> satisfied; device
#          flagged skip-assigned-user -> N/A (satisfied); owner resolves ->
#          re-run 10-setup-user.ps1; owner does NOT resolve -> RETRY (never
#          fabricate an account), and after the attempt budget, log a breadcrumb
#          + inventory event and stop (junadmin still makes the box reachable).
#   3. Writes an `.ok` marker per critical once satisfied ("triggered" flag).
#   4. UNREGISTERS ITSELF once both criticals are satisfied-or-given-up, so it
#      never lingers on a healthy machine.
#
# Idempotent + best-effort: it must never throw, never wipe a good state, and
# never block. It reuses the SAME phase scripts (one source of truth).

$ErrorActionPreference = 'SilentlyContinue'

$SetupRoot  = 'C:\ProgramData\JuniperSetup'
$ScriptsDir = "$SetupRoot\scripts"
$StateDir   = "$SetupRoot\state"
$LogFile    = "$SetupRoot\logs\ensure-critical.log"
$StateFile  = "$StateDir\ensure-critical.json"
$WifiOk     = "$StateDir\join-wifi.ok"
$UserOk     = "$StateDir\setup-user.ok"
$TaskName   = 'JuniperEnsureCritical'
$ImagingTask= 'JuniperImaging'
$InvIp      = 'http://192.168.5.141:8080'          # pc-deploy (IP; .local may not resolve)
$MaxAttempts= 15                                    # per-critical retry budget before we log + stop

foreach ($d in @($StateDir, "$SetupRoot\logs")) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Log { param([string]$m)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try { Add-Content -Path $LogFile -Value "$ts  $m" -Encoding UTF8 } catch {}
    Write-Host $m
}

# progress.ps1 gives us Publish-Event (posts to the inventory timeline); no-op fallback.
try { . "$SetupRoot\progress.ps1" } catch {}
if (-not (Get-Command Publish-Event -ErrorAction SilentlyContinue)) {
    function Publish-Event { param([Parameter(ValueFromRemainingArguments)]$a) }
}

function Get-State {
    if (Test-Path $StateFile) { try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ wifi_attempts = 0; user_attempts = 0; wifi_gaveup = $false; user_gaveup = $false }
}
function Save-State { param($s) try { $s | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8 } catch {} }
function Mark-Ok  { param([string]$Path,[string]$How) try { "{0}  {1}" -f (Get-Date).ToString('s'),$How | Set-Content $Path -Encoding UTF8 } catch {} }

# --- Concurrency guard: let the orchestrator work if it is actively running ---
try {
    $it = Get-ScheduledTask -TaskName $ImagingTask -ErrorAction SilentlyContinue
    if ($it -and $it.State -eq 'Running') {
        Log "JuniperImaging is Running - orchestrator active; deferring."
        return
    }
} catch {}

$state = Get-State

# =====================================================================
#  Wi-Fi
# =====================================================================
function Get-WifiConnection {
    Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' } | Select-Object -First 1
}
function Get-WlanProfiles {
    try { (netsh wlan show profiles) | Select-String 'All User Profile\s*:\s*(.+)$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Where-Object { $_ } } catch { @() }
}
function Set-WifiCoexist {
    param($Nic)
    # THE root-cause fix: by default Windows drops/skips Wi-Fi whenever a wired link
    # is up ("minimize simultaneous connections"). During imaging the wired dongle is
    # always present, so a saved auto Wi-Fi profile never actually connects and every
    # reboot comes up wired-only. fMinimizeConnections=0 lets Wi-Fi stay up alongside
    # Ethernet; we also make sure WLAN autoconfig is enabled on the adapter.
    try {
        $gp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'
        if (-not (Test-Path $gp)) { New-Item -Path $gp -Force | Out-Null }
        Set-ItemProperty -Path $gp -Name 'fMinimizeConnections' -Value 0 -Type DWord -Force
    } catch {}
    try { if ($Nic) { netsh wlan set autoconfig enabled=yes interface="$($Nic.Name)" 2>&1 | Out-Null } } catch {}
}

function Ensure-Wifi {
    if (Test-Path $WifiOk) { return $true }

    $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
           Where-Object { $_.PhysicalMediaType -match 'Native 802.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' } |
           Select-Object -First 1
    if (-not $nic) {
        Log "Wi-Fi: no wireless adapter present - N/A (satisfied)."
        Mark-Ok $WifiOk 'na-no-adapter'
        return $true
    }

    # Always assert coexistence-with-wired + autoconfig first (idempotent).
    Set-WifiCoexist -Nic $nic

    $connected = Get-WifiConnection
    if ($connected) {
        try { Set-NetConnectionProfile -InterfaceIndex $connected.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}
        Log "Wi-Fi: already connected to '$($connected.Name)' (coexist set, profile Private). Satisfied."
        Mark-Ok $WifiOk "connected:$($connected.Name)"
        return $true
    }

    # Not connected. Resolve the office SSID (server preferred, else a saved profile).
    $ssid = $null
    try { $ssid = "$((Invoke-RestMethod "$InvIp/api/management/wifi" -TimeoutSec 8 -ErrorAction Stop).ssid)".Trim() } catch {}
    $profiles = Get-WlanProfiles
    if (-not $ssid) { $ssid = @($profiles)[0] }

    # If the office profile isn't saved yet, run 06 to fetch creds + add it (user=all/auto).
    if ($ssid -and (@($profiles) -notcontains $ssid)) {
        Log "Wi-Fi: profile '$ssid' not saved yet - running 06-join-wifi.ps1 to add it."
        Publish-Event -PhaseKey 'join-wifi' -Step 'ensure-critical' -Status 'running' -Message "Safety-net adding Wi-Fi profile '$ssid'."
        try { & "$ScriptsDir\06-join-wifi.ps1" -InventoryUrl $InvIp | Out-Null } catch { Log "Wi-Fi: 06 threw: $_" }
        $profiles = Get-WlanProfiles
        if (-not $ssid) { $ssid = @($profiles)[0] }
    }

    if (-not $ssid) {
        $state.wifi_attempts++
        Log "Wi-Fi: no SSID resolved and no saved profile (attempt $($state.wifi_attempts)/$MaxAttempts) - creds API likely unreachable. Retry."
        if ($state.wifi_attempts -ge $MaxAttempts) { $state.wifi_gaveup = $true; Publish-Event -PhaseKey 'join-wifi' -Step 'ensure-critical' -Status 'warning' -Message 'Safety-net had no Wi-Fi SSID/profile to connect after retries - gave up.' }
        return $false
    }

    # Trigger the association. NOTE (Win11): `netsh wlan connect` and any WLAN scan
    # require Location services, which are OFF on a fresh image -> it returns
    # "Access is denied / WlanGetAvailableNetworkList error 5". So we do NOT rely on
    # it. The reliable lever is fMinimizeConnections=0 (Set-WifiCoexist above), which
    # lets WLAN AutoConfig auto-connect the saved auto profile even with the wired
    # dongle up. We NUDGE AutoConfig by bouncing the adapter (needs no Location perm),
    # and still fire netsh connect best-effort in case Location happens to be on.
    Log "Wi-Fi: not connected - nudging AutoConfig to associate '$ssid' (coexist policy set)."
    Publish-Event -PhaseKey 'join-wifi' -Step 'ensure-critical' -Status 'running' -Message "Safety-net connecting Wi-Fi to '$ssid' (AutoConfig, coexist-with-wired)."
    try { netsh wlan connect name="$ssid" 2>&1 | Out-Null } catch {}
    try { Restart-NetAdapter -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
    Start-Sleep 12

    $now = Get-WifiConnection
    if ($now) {
        try { Set-NetConnectionProfile -InterfaceIndex $now.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}
        Log "Wi-Fi: connected to '$($now.Name)' after explicit connect (set Private)."
        Publish-Event -PhaseKey 'join-wifi' -Step 'ensure-critical' -Status 'ok' -Message "Safety-net connected Wi-Fi '$($now.Name)' (explicit connect) and set profile Private."
        Mark-Ok $WifiOk "ensure:$($now.Name)"
        return $true
    }
    $state.wifi_attempts++
    Log "Wi-Fi: explicit connect to '$ssid' did not confirm (attempt $($state.wifi_attempts)/$MaxAttempts)."
    if ($state.wifi_attempts -ge $MaxAttempts) {
        $state.wifi_gaveup = $true
        Publish-Event -PhaseKey 'join-wifi' -Step 'ensure-critical' -Status 'warning' -Message "Safety-net could not associate Wi-Fi '$ssid' after retries - gave up (out of range / bad PSK?)."
    }
    return $false
}

# =====================================================================
#  Assigned-user local account
# =====================================================================
function Test-UserAccountExists {
    # A local_<name> account (what 10-setup-user creates) already present = satisfied.
    $u = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'local_*' -and $_.Enabled }
    return [bool]$u
}

function Ensure-User {
    if (Test-Path $UserOk) { return $true }

    if (Test-UserAccountExists) {
        Log "User: a local_* account already exists. Satisfied."
        Mark-Ok $UserOk 'account-present'
        return $true
    }

    # Resolve BIOS serial (same validation 10-setup-user uses).
    $serial = $null
    foreach ($src in @({ (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber },
                       { (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).SerialNumber })) {
        try { $v = "$(& $src)".Trim()
              if ($v -and $v -notmatch '^(0+|To be filled.*|Default string|None|N/?A|System Serial Number|\.+)$') { $serial = $v; break } } catch {}
    }
    if (-not $serial) {
        $state.user_attempts++
        Log "User: no usable BIOS serial (attempt $($state.user_attempts)/$MaxAttempts) - cannot resolve owner; will retry."
        if ($state.user_attempts -ge $MaxAttempts) { $state.user_gaveup = $true; Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'warning' -Message 'Safety-net could not read a usable serial - gave up; junadmin only.' }
        return $false
    }

    # Ask the token-free assigned-user endpoint.
    $au = $null
    try { $au = Invoke-RestMethod ("$InvIp/ingest/deploy/assigned-user?serial=" + [uri]::EscapeDataString($serial)) -TimeoutSec 15 -ErrorAction Stop } catch {}
    if ($null -eq $au) {
        $state.user_attempts++
        Log "User: assigned-user API unreachable (attempt $($state.user_attempts)/$MaxAttempts) - retry (likely network not up yet)."
        if ($state.user_attempts -ge $MaxAttempts) { $state.user_gaveup = $true; Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'warning' -Message 'Safety-net could not reach the inventory server to resolve the assigned user - gave up; junadmin only.' }
        return $false
    }

    # Deliberate policy: junadmin-only device -> N/A (satisfied, do NOT create).
    if ($au.skip_assigned_user_account -eq $true -or "$($au.skip_assigned_user_account)" -match '^(?i:true|1)$') {
        Log "User: device flagged skip-assigned-user in inventory - junadmin only. N/A (satisfied)."
        Mark-Ok $UserOk 'na-skip-flag'
        return $true
    }

    $ownerEmail = "$($au.owner_email)".Trim()
    $ownerName  = "$($au.name)".Trim()
    if (-not $ownerEmail -and -not $ownerName) {
        # No owner assigned in inventory. Per policy: retry, then log - NEVER guess.
        $state.user_attempts++
        Log "User: no owner assigned on this device record (attempt $($state.user_attempts)/$MaxAttempts) - NOT creating a generic account; will retry."
        if ($state.user_attempts -ge $MaxAttempts) {
            $state.user_gaveup = $true
            Log "User: no owner after budget - giving up. Assign an owner in inventory + re-run to create the account. junadmin remains for access."
            Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'warning' -Message 'Safety-net: no assigned owner in inventory after retries - no local account created (junadmin only). Assign an owner and re-image/re-run.'
        }
        return $false
    }

    # Owner resolves -> re-run the real phase script (single source of truth).
    $ownerLabel = if ($ownerEmail) { $ownerEmail } else { $ownerName }
    Log "User: owner resolved ($ownerLabel) - running 10-setup-user.ps1 (safety net)."
    Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'running' -Message 'Safety-net re-running assigned-user setup (main pass did not create the account).'
    try { & "$ScriptsDir\10-setup-user.ps1" -InventoryUrl $InvIp | Out-Null } catch { Log "User: 10 threw: $_" }

    if (Test-UserAccountExists) {
        Log "User: local_* account present after safety-net run. Satisfied."
        Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'ok' -Message 'Safety-net created the assigned-user local account.'
        Mark-Ok $UserOk 'ensure-created'
        return $true
    }
    $state.user_attempts++
    Log "User: safety-net run did not produce an account (attempt $($state.user_attempts)/$MaxAttempts) - may be missing initial-password config."
    if ($state.user_attempts -ge $MaxAttempts) { $state.user_gaveup = $true; Publish-Event -PhaseKey 'setup-user' -Step 'ensure-critical' -Status 'warning' -Message 'Safety-net could not create the account after retries (check user-init.json) - gave up; junadmin only.' }
    return $false
}

# =====================================================================
#  Run + self-teardown
# =====================================================================
Log "=== ensure-critical fire (imaging='$([string]($it.State))') ==="
$wifiSat = Ensure-Wifi
$userSat = Ensure-User
Save-State $state

$wifiDone = $wifiSat -or $state.wifi_gaveup
$userDone = $userSat -or $state.user_gaveup
Log "Result: wifi satisfied=$wifiSat gaveup=$($state.wifi_gaveup) | user satisfied=$userSat gaveup=$($state.user_gaveup)"

if ($wifiDone -and $userDone) {
    Log "Both criticals resolved (satisfied or given up) - unregistering $TaskName."
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
exit 0
