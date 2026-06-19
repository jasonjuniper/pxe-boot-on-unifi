# wim-update-deploy-boot.ps1
# Surgical WIM update: replace deploy-boot.ps1 in boot.wim
# Run as SYSTEM via Scheduled Task on pc-deploy (WinRM process isolation breaks DISM dismount)

param(
    [string]$SourceWim   = 'C:\tftpd64\sources\boot.wim',
    [string]$WorkWim     = 'C:\imaging-build\boot.wim',
    [string]$MountDir    = 'C:\imaging-build\mount',
    [string]$ScriptShare = '\\192.168.5.141\deploy$\scripts\winpe\deploy-boot.ps1'
)

$ErrorActionPreference = 'Stop'
$log = 'C:\imaging-build\wim-update-deploy-boot.log'
function Log($msg) { $ts = Get-Date -Format 'HH:mm:ss'; "$ts  $msg" | Tee-Object -FilePath $log -Append | Write-Host }

Log 'Starting deploy-boot.ps1 WIM update...'

# 1. Clean up any leftover mount
if (Test-Path $MountDir) {
    Log 'Cleaning up prior mount...'
    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue
    Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item $MountDir -ItemType Directory -Force | Out-Null

# 2. Copy source WIM to working location
Log "Copying $SourceWim -> $WorkWim"
if (Test-Path $WorkWim) { Remove-Item $WorkWim -Force }
Copy-Item $SourceWim $WorkWim -Force
Log "Copied. Size: $([math]::Round((Get-Item $WorkWim).Length/1MB)) MB"

# 3. Mount WIM index 1
Log 'Mounting WIM index 1...'
Mount-WindowsImage -ImagePath $WorkWim -Index 1 -Path $MountDir
Log 'Mounted.'

# 4. Replace deploy-boot.ps1
$dst = "$MountDir\Windows\System32\deploy-boot.ps1"
Log "Replacing deploy-boot.ps1..."
# Source: read from the deploy share script location
$srcContent = Get-Content '\\192.168.5.141\deploy$\scripts\winpe\deploy-boot.ps1' -Raw -ErrorAction SilentlyContinue
if (-not $srcContent) {
    # Fallback: look in the same directory as this script
    $scriptDir = Split-Path $MyInvocation.MyCommand.Path
    $srcContent = Get-Content "$scriptDir\..\winpe\deploy-boot.ps1" -Raw -ErrorAction SilentlyContinue
}
if (-not $srcContent) {
    Log 'ERROR: Cannot find deploy-boot.ps1 source. Aborting.'
    Dismount-WindowsImage -Path $MountDir -Discard
    exit 1
}
[System.IO.File]::WriteAllText($dst, $srcContent, [System.Text.UTF8Encoding]::new($true))
Log "deploy-boot.ps1 updated in WIM."

# 5. Dismount and save
Log 'Saving WIM (this takes a minute)...'
Dismount-WindowsImage -Path $MountDir -Save
Log "WIM saved. Size: $([math]::Round((Get-Item $WorkWim).Length/1MB)) MB"

# 6. Deploy to both TFTP and WinPE media
Log 'Deploying to C:\tftpd64\sources\boot.wim ...'
Copy-Item $WorkWim 'C:\tftpd64\sources\boot.wim' -Force
Log 'Deploying to C:\WinPE_amd64\media\sources\boot.wim ...'
Copy-Item $WorkWim 'C:\WinPE_amd64\media\sources\boot.wim' -Force

Log 'Done. WIM updated and deployed.'
