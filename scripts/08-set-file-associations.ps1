# 08-set-file-associations.ps1
# Sets 7-Zip as the default handler for all archive types (ISO excluded).
# Must run as Administrator/SYSTEM.
#
# USAGE:
#   .\08-set-file-associations.ps1
#   .\08-set-file-associations.ps1 -DryRun
#
# Strategy (four layers, each reinforces the next):
#   1. Ensure 7-Zip ProgID is registered correctly in HKCR
#   2. Set HKCR\.<ext> default value to 7-Zip ProgID (system-wide fallback)
#   3. Delete UserChoice keys from every existing user profile so HKCR wins
#   4. Import DefaultAppAssociations XML via DISM (applies to future profiles)
#   5. Patch C:\Users\Default NTUSER.DAT so new accounts start clean

param([switch]$DryRun)
$ErrorActionPreference = 'Stop'

# --- Extensions to assign to 7-Zip (ISO explicitly excluded) -----------------
$Archives = @(
    '.7z', '.zip', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.bz',
    '.xz', '.cab', '.arj', '.z', '.lzh', '.lha', '.lzma',
    '.wim', '.swm', '.001', '.cpio'
)

Write-Host ''
Write-Host '==> 7-Zip file associations' -ForegroundColor Cyan
if ($DryRun) { Write-Host '    (Dry run -- no changes will be made)' -ForegroundColor Yellow }

# 1. Verify 7-Zip is installed ------------------------------------------------
$szFM = 'C:\Program Files\7-Zip\7zFM.exe'
if (-not (Test-Path $szFM)) {
    Write-Error "7-Zip not found at $szFM. Run 04-install-packages.ps1 first."
    exit 1
}
Write-Host "  7-Zip: $szFM" -ForegroundColor Green

# Mount HKCR and HKU as PS drives if not already present
foreach ($drv in @(@{Name='HKCR';Root='HKEY_CLASSES_ROOT'}, @{Name='HKU';Root='HKEY_USERS'})) {
    if (-not (Get-PSDrive -Name $drv.Name -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $drv.Name -PSProvider Registry -Root $drv.Root | Out-Null
    }
}

# 2. Ensure 7-Zip ProgID exists in HKCR --------------------------------------
$progId   = '7-Zip.Document'
$progPath = "HKCR:\$progId"

if (-not (Test-Path $progPath)) {
    Write-Host "  Creating HKCR ProgID: $progId" -ForegroundColor Yellow
    if (-not $DryRun) {
        New-Item  "$progPath"                    -Force | Out-Null
        Set-ItemProperty "$progPath"             -Name '(default)' -Value '7-Zip Document'
        New-Item  "$progPath\DefaultIcon"        -Force | Out-Null
        Set-ItemProperty "$progPath\DefaultIcon" -Name '(default)' -Value "`"$szFM`",0"
        New-Item  "$progPath\shell\open\command" -Force | Out-Null
        Set-ItemProperty "$progPath\shell\open\command" -Name '(default)' -Value "`"$szFM`" `"%1`""
    }
} else {
    Write-Host "  ProgID $progId already registered." -ForegroundColor DarkGray
}

# 3. Set HKCR\.<ext> defaults -------------------------------------------------
Write-Host "  Setting HKCR defaults for $($Archives.Count) extensions..." -ForegroundColor Cyan
foreach ($ext in $Archives) {
    $extPath = "HKCR:\$ext"
    if ($DryRun) { Write-Host "    [DryRun] $ext -> $progId"; continue }
    if (-not (Test-Path $extPath)) { New-Item $extPath -Force | Out-Null }
    Set-ItemProperty $extPath -Name '(default)' -Value $progId
    $owpPath = "$extPath\OpenWithProgids"
    if (-not (Test-Path $owpPath)) { New-Item $owpPath -Force | Out-Null }
    New-ItemProperty $owpPath -Name $progId -Value ([byte[]]@()) `
        -PropertyType Binary -Force | Out-Null
}
if (-not $DryRun) { Write-Host "  HKCR defaults set." -ForegroundColor Green }

# 4. Clear UserChoice from every loaded and offline user profile --------------
# UserChoice overrides HKCR; removing it causes Windows to fall back to HKCR.
Write-Host "  Clearing UserChoice overrides from user profiles..." -ForegroundColor Cyan

$profileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' |
    Where-Object { $_.ProfileImagePath -notmatch 'systemprofile|LocalService|NetworkService' }

foreach ($profile in $profileList) {
    $sid       = Split-Path $profile.PSPath -Leaf
    $userName  = Split-Path $profile.ProfileImagePath -Leaf
    $hivePath  = Join-Path $profile.ProfileImagePath 'NTUSER.DAT'
    $hiveKey   = "HKU\JFASSOC_$sid"
    $hiveMount = $false

    # Use already-loaded hive, or load it offline
    if (-not (Test-Path "HKU:\$sid")) {
        if (-not (Test-Path $hivePath)) {
            Write-Host "    SKIP $userName : NTUSER.DAT not found" -ForegroundColor DarkGray
            continue
        }
        if (-not $DryRun) {
            reg load $hiveKey $hivePath 2>$null | Out-Null
            $hiveMount = $true
        }
    }

    $cleared = 0
    foreach ($ext in $Archives) {
        if ($DryRun) { $cleared++; continue }
        $baseKey = if ($hiveMount) { "HKU:\JFASSOC_$sid" } else { "HKU:\$sid" }
        $ucPath  = "$baseKey\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
        if (Test-Path $ucPath) {
            Remove-Item $ucPath -Recurse -Force -ErrorAction SilentlyContinue
            $cleared++
        }
    }

    if ($hiveMount) {
        [GC]::Collect(); Start-Sleep -Milliseconds 300
        reg unload $hiveKey 2>$null | Out-Null
    }

    Write-Host ("    {0,-20} cleared {1} UserChoice entries" -f $userName, $cleared) -ForegroundColor DarkGray
}

# 5. Patch Default User hive for new accounts ---------------------------------
Write-Host "  Patching Default User hive..." -ForegroundColor Cyan
$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if (Test-Path $defaultHive) {
    $defKey = 'HKU\JFASSOC_DEFAULT'
    if (-not $DryRun) {
        reg load $defKey $defaultHive 2>$null | Out-Null
        foreach ($ext in $Archives) {
            reg delete "$defKey\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice" `
                /f 2>$null | Out-Null
        }
        [GC]::Collect(); Start-Sleep -Milliseconds 300
        reg unload $defKey 2>$null | Out-Null
        Write-Host "  Default User hive patched." -ForegroundColor Green
    } else {
        Write-Host "  [DryRun] Would patch $defaultHive"
    }
}

# 6. Import DefaultAppAssociations XML via DISM (new-profile fallback) --------
Write-Host "  Importing DefaultAppAssociations XML via DISM..." -ForegroundColor Cyan
$xmlPath = "$env:TEMP\juniper-7zip-assoc.xml"
$xml = @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>')
foreach ($ext in $Archives) {
    $xml += "  <Association Identifier=`"$ext`" ProgId=`"$progId`" ApplicationName=`"7-Zip File Manager`" />"
}
$xml += '</DefaultAssociations>'
$xml -join "`n" | Set-Content $xmlPath -Encoding UTF8

if (-not $DryRun) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process dism `
        -ArgumentList "/Online /Import-DefaultAppAssociations /DefaultAppAssociationsFile:`"$xmlPath`"" `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $err = Get-Content $e -Raw -ErrorAction SilentlyContinue
    Remove-Item $o,$e,$xmlPath -ErrorAction SilentlyContinue
    if ($p.ExitCode -eq 0) {
        Write-Host "  DefaultAppAssociations imported." -ForegroundColor Green
    } else {
        Write-Host "  WARN: DISM exit $($p.ExitCode) -- associations may not apply to new profiles." -ForegroundColor Yellow
        if ($err) { Write-Host "  $($err.Trim())" -ForegroundColor DarkGray }
    }
} else {
    Write-Host "  [DryRun] Would import $xmlPath"
    Remove-Item $xmlPath -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '==> 7-Zip file associations complete.' -ForegroundColor Green
Write-Host '    Users already logged in need to log off and back on to see the change.' -ForegroundColor DarkGray
