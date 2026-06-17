# wim-update4.ps1
# Surgical WIM update: replace deploy-boot.ps1 (and optionally toolkit.ps1)
# inside boot.wim from the credentialed staging directory.
#
# Run as SYSTEM via the 'WimUpdate4' scheduled task on pc-deploy.
# Triggered by wim-bake-credentials.ps1 after it writes the password-substituted
# deploy-boot.ps1 to C:\deploy\staging\.
#
# Log written to C:\imaging-build\wim-update4.log (read back by wim-bake-credentials.ps1)

param(
    [string]$SourceWim  = 'C:\tftpd64\sources\boot.wim',
    [string]$WorkWim    = 'C:\imaging-build\boot.wim',
    [string]$MountDir   = 'C:\imaging-build\mount',
    [string]$StagingDir = 'C:\deploy\staging'
)

$ErrorActionPreference = 'Stop'
$log = 'C:\imaging-build\wim-update4.log'
function Log($msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    "$ts  $msg" | Tee-Object -FilePath $log -Append | Write-Host
}

New-Item (Split-Path $log) -ItemType Directory -Force | Out-Null
Set-Content $log ''   # reset log for this run

Log 'WimUpdate4 starting...'

# 1. Clean up any leftover mount from a prior failed run
if (Test-Path $MountDir) {
    Log 'Cleaning up prior mount...'
    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue
    Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item $MountDir -ItemType Directory -Force | Out-Null

# 2. Copy live boot.wim to a working path (never modify the live file in place)
Log "Copying $SourceWim -> $WorkWim"
if (-not (Test-Path $SourceWim)) {
    Log "ERROR: $SourceWim not found. Was 01c-build-winpe.ps1 run on this machine?"
    exit 1
}
if (Test-Path $WorkWim) { Remove-Item $WorkWim -Force }
Copy-Item $SourceWim $WorkWim -Force
Log "Copied. Size: $([math]::Round((Get-Item $WorkWim).Length / 1MB)) MB"

# 3. Mount WIM index 1
Log 'Mounting WIM index 1...'
Mount-WindowsImage -ImagePath $WorkWim -Index 1 -Path $MountDir
Log 'Mounted.'

# 4. Replace deploy-boot.ps1 from staging (contains substituted credentials)
$stagingBoot = "$StagingDir\deploy-boot.ps1"
if (-not (Test-Path $stagingBoot)) {
    Log "ERROR: $stagingBoot not found. Aborting."
    Dismount-WindowsImage -Path $MountDir -Discard
    exit 1
}
$srcContent = [System.IO.File]::ReadAllText($stagingBoot)
if ($srcContent -match '##WINPE_PASS##') {
    Log 'ERROR: ##WINPE_PASS## placeholder still present in staging file - credential substitution failed.'
    Dismount-WindowsImage -Path $MountDir -Discard
    exit 1
}
$dst = "$MountDir\Windows\System32\deploy-boot.ps1"
Log 'Replacing deploy-boot.ps1...'
[System.IO.File]::WriteAllText($dst, $srcContent, [System.Text.UTF8Encoding]::new($true))
Log 'deploy-boot.ps1 updated.'

# 5. Replace toolkit.ps1 from staging if provided
$stagingToolkit = "$StagingDir\toolkit.ps1"
if (Test-Path $stagingToolkit) {
    $dstToolkit = "$MountDir\Windows\System32\toolkit.ps1"
    Copy-Item $stagingToolkit $dstToolkit -Force
    Log 'toolkit.ps1 updated.'
}

# 6. Dismount and commit
Log 'Saving WIM (may take a minute)...'
Dismount-WindowsImage -Path $MountDir -Save
Log "WIM saved. Size: $([math]::Round((Get-Item $WorkWim).Length / 1MB)) MB"

# 7. Deploy to TFTP root (PXE) and WinPE media (USB source)
Log 'Deploying to C:\tftpd64\sources\boot.wim ...'
Copy-Item $WorkWim 'C:\tftpd64\sources\boot.wim' -Force
if (Test-Path 'C:\WinPE_amd64\media\sources') {
    Log 'Deploying to C:\WinPE_amd64\media\sources\boot.wim ...'
    Copy-Item $WorkWim 'C:\WinPE_amd64\media\sources\boot.wim' -Force
}

Log 'WimUpdate4 complete.'
