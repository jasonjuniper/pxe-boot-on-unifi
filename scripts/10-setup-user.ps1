# 10-setup-user.ps1
# Creates the assigned end-user's LOCAL account on a freshly-imaged PC.
#
# Looks up the machine in inventory (by BIOS serial), reads the assigned owner
# (owner_email preferred, then primary_user_email), derives a valid local
# account name, creates the account, adds it to the local Administrators group,
# and forces a password change at first logon.
#
# The generic initial password is fetched from the inventory server's
# /api/management/user-init endpoint (RFC-1918 only) - it is NEVER stored in
# this repo or in any script.  Configure C:\inventory\user-init.json on
# pc-deploy:  {"initialPassword": "..."}.  The password is held in memory only,
# cleared immediately after use, and never written to any log.
#
# BEST-EFFORT during imaging: no owner assigned, an unreachable inventory API,
# a reserved/invalid account name, or a missing initial-password config must
# NEVER abort the image.  Every failure path exits 0.
#
# USAGE: .\10-setup-user.ps1

param(
    [string]$InventoryUrl = 'http://inventory.juniperdesign.local:8080',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# This phase is BEST-EFFORT: a missing owner / unreachable API / policy reject
# must not fail the image.  Trap everything and exit 0.
trap {
    Write-Host "WARN: setup-user hit a non-fatal error: $_" -ForegroundColor Yellow
    exit 0
}

# Built-in / management accounts we must never collide with or recreate.
$Reserved = @('junadmin','administrator','administrators','guest','admin',
              'defaultaccount','wdagutilityaccount','system','localsystem')

# --- Derive a valid Windows local account name from an email/UPN or full name -
function Get-AccountName {
    param([string]$Email, [string]$Name)
    $base = $null
    if ($Email -and $Email -match '@') {
        $base = ($Email -split '@')[0]
    } elseif ($Email) {
        $base = $Email
    }
    if (-not $base -and $Name) {
        $parts = @($Name -split '\s+' | Where-Object { $_ })
        if     ($parts.Count -ge 2) { $base = $parts[0].Substring(0,1) + $parts[-1] }
        elseif ($parts.Count -eq 1) { $base = $parts[0] }
    }
    if (-not $base) { return $null }
    # Local usernames: <=20 chars, no  " / \ [ ] : ; | = , + * ? < > @ .
    # Keep letters/digits/dot/hyphen/underscore; strip the rest.
    $base = $base.ToLower() -replace '[^a-z0-9._-]', ''
    $base = $base -replace '^\.+', ''     # no leading dot
    $base = $base -replace '\.+$', ''     # no trailing dot
    if ($base.Length -gt 20) { $base = $base.Substring(0,20) -replace '\.+$', '' }
    if (-not $base) { return $null }
    return $base
}

# --- 1. Identify this machine by BIOS serial --------------------------------
$serial = $null
foreach ($src in @(
    { (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber },
    { (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).SerialNumber }
)) {
    try {
        $v = (& $src)
        if ($v) { $v = "$v".Trim() }
        if ($v -and $v -notmatch '^(0+|To be filled.*|Default string|None|N/?A|System Serial Number|\.+)$') {
            $serial = $v; break
        }
    } catch {}
}
if (-not $serial) {
    Write-Host "No usable BIOS serial - cannot resolve assigned user. Skipping (not an error)." -ForegroundColor Yellow
    exit 0
}
Write-Host "==> setup-user: resolved serial '$serial'" -ForegroundColor Cyan

# --- 2. Look up the assigned owner in inventory -----------------------------
$ownerEmail = $null; $ownerName = $null; $deviceId = $null
try {
    $hits = Invoke-RestMethod ("$InventoryUrl/api/devices?q=" + [uri]::EscapeDataString($serial)) -TimeoutSec 15 -ErrorAction Stop
} catch {
    Write-Host "WARN: inventory device lookup failed ($InventoryUrl): $_" -ForegroundColor Yellow
    exit 0
}
$match = @($hits | Where-Object { "$($_.serial_number)".Trim().ToLower() -eq $serial.ToLower() }) | Select-Object -First 1
if (-not $match) { $match = @($hits) | Select-Object -First 1 }   # single-result fallback
if ($match) {
    $deviceId   = $match.id
    $ownerEmail = "$($match.owner_email)".Trim()
    $ownerName  = "$($match.owner)".Trim()
}

# Fallback: device record has no linked owner -> use the auto-discovered
# primary user from the last agent snapshot (system_info.primary_user_*).
if ((-not $ownerEmail) -and $deviceId) {
    try {
        $detail = Invoke-RestMethod "$InventoryUrl/api/device/$deviceId" -TimeoutSec 15 -ErrorAction Stop
        $si = $detail.system_info
        if ($si) {
            if ($si.primary_user_email) { $ownerEmail = "$($si.primary_user_email)".Trim() }
            if (-not $ownerName -and $si.primary_user_name) { $ownerName = "$($si.primary_user_name)".Trim() }
        }
    } catch {}
}

if (-not $ownerEmail -and -not $ownerName) {
    Write-Host "No assigned user on this device record - skipping local-account setup (not an error)." -ForegroundColor Yellow
    exit 0
}

# --- 3. Derive + validate the account name ----------------------------------
$acct = Get-AccountName -Email $ownerEmail -Name $ownerName
if (-not $acct) {
    Write-Host "WARN: could not derive a valid account name from owner ('$ownerEmail' / '$ownerName'). Skipping." -ForegroundColor Yellow
    exit 0
}
if ($Reserved -contains $acct.ToLower()) {
    Write-Host "WARN: derived account '$acct' is reserved - skipping to avoid collision." -ForegroundColor Yellow
    exit 0
}
$fullName = if ($ownerName) { $ownerName } else { $acct }
Write-Host "==> setup-user: assigned user account = '$acct' (full name '$fullName')" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "(Dry run - would create/update local admin '$acct' with forced password change.)" -ForegroundColor Yellow
    exit 0
}

# --- 4. Fetch the generic initial password (server-side; never in repo) ------
$initPw = $null
try {
    $resp   = Invoke-RestMethod "$InventoryUrl/api/management/user-init" -TimeoutSec 10 -ErrorAction Stop
    $initPw = $resp.initialPassword
} catch {
    Write-Host "WARN: could not fetch initial password from $InventoryUrl/api/management/user-init: $_" -ForegroundColor Yellow
    Write-Host "  Set C:\inventory\user-init.json on pc-deploy: {`"initialPassword`":`"...`"}" -ForegroundColor Yellow
    exit 0
}
if (-not $initPw) {
    Write-Host "WARN: inventory returned an empty initial password. Check C:\inventory\user-init.json." -ForegroundColor Yellow
    exit 0
}

# --- 5. Create / update the account, add to Administrators, force change -----
$sec = ConvertTo-SecureString $initPw -AsPlainText -Force
$initPw = $null   # plaintext cleared immediately; only the SecureString remains

$existing = Get-LocalUser -Name $acct -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Local account '$acct' already exists - resetting password + ensuring admin." -ForegroundColor Cyan
    Set-LocalUser -Name $acct -Password $sec -FullName $fullName
    Enable-LocalUser -Name $acct -ErrorAction SilentlyContinue
} else {
    Write-Host "  Creating local account '$acct'." -ForegroundColor Cyan
    New-LocalUser -Name $acct -Password $sec -FullName $fullName `
        -Description 'Juniper assigned user' -AccountNeverExpires | Out-Null
}
$sec = $null   # drop the SecureString too

# Add to local Administrators (idempotent)
$inAdmins = $false
try { $inAdmins = [bool](Get-LocalGroupMember -Group 'Administrators' -Member $acct -ErrorAction SilentlyContinue) } catch {}
if (-not $inAdmins) {
    Add-LocalGroupMember -Group 'Administrators' -Member $acct -ErrorAction SilentlyContinue
    Write-Host "  Added '$acct' to Administrators." -ForegroundColor Green
} else {
    Write-Host "  '$acct' already in Administrators." -ForegroundColor Green
}

# Force password change at first logon (PasswordExpired = 1 via ADSI).
# Must run AFTER Set/New-LocalUser, which reset PasswordLastSet.
try {
    ([ADSI]"WinNT://./$acct,user").PasswordExpired = 1
    Write-Host "  '$acct' must change password at first logon." -ForegroundColor Green
} catch {
    Write-Host "  WARN: could not set must-change-at-logon flag: $_" -ForegroundColor Yellow
}

Write-Host "setup-user complete for '$acct'." -ForegroundColor Green
exit 0
