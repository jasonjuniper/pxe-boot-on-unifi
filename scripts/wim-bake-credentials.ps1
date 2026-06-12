# wim-bake-credentials.ps1
# Run from ENG-2 (interactive -- prompts for the junadmin password once).
#
# Substitutes the password into deploy-boot.ps1, pushes the credentialed version
# to pc-deploy, triggers the WIM rebuild, waits for it, then scrubs the
# plain-text credential file from the share.
#
# The password lives only in the WIM -- never in this repo or in any file on disk.
#
# USAGE:
#   .\scripts\wim-bake-credentials.ps1
#   .\scripts\wim-bake-credentials.ps1 -CopyToUsb   # also writes boot.wim to USB (D:\sources\)

param(
    [switch]$CopyToUsb,
    [string]$DeployServer = '192.168.5.141'
)

$ErrorActionPreference = 'Stop'

# Verify placeholder is present before asking for the password
$templatePath = "$PSScriptRoot\..\winpe\deploy-boot.ps1"
$template = Get-Content $templatePath -Raw
if ($template -notmatch '##WINPE_PASS##') {
    Write-Error "deploy-boot.ps1 does not contain ##WINPE_PASS##. Was a real password accidentally committed?"
    exit 1
}

Write-Host ''
Write-Host '  Juniper WinPE credential bake' -ForegroundColor Cyan
Write-Host '  Enter the junadmin password. It will be baked into the WIM and' -ForegroundColor DarkGray
Write-Host '  never written to disk in plain text.' -ForegroundColor DarkGray
Write-Host ''
$secPass = Read-Host '  junadmin password' -AsSecureString
$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
$pass    = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

if (-not $pass) { Write-Error 'No password entered.'; exit 1 }

# Substitute into template
$credScript = $template -replace '##WINPE_PASS##', $pass
$pass       = $null   # clear from memory immediately after substitution

Write-Host ''
Write-Host '==> Pushing credentialed deploy-boot.ps1 + toolkit.ps1 to pc-deploy...' -ForegroundColor Cyan
$session = New-PSSession -ComputerName $DeployServer
Invoke-Command -Session $session -ScriptBlock {
    param($content)
    $path = 'C:\deploy\staging\deploy-boot.ps1'
    New-Item (Split-Path $path) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    "Written: $path  ($([math]::Round($content.Length/1KB,1)) KB)"
} -ArgumentList $credScript
$credScript = $null   # clear from memory

# Also push toolkit.ps1 to staging so WimUpdate4 bakes it in too
$toolkitSrc = "$PSScriptRoot\..\winpe\toolkit.ps1"
if (Test-Path $toolkitSrc) {
    $toolkitContent = [System.IO.File]::ReadAllBytes($toolkitSrc)
    Invoke-Command -Session $session -ScriptBlock {
        param($bytes)
        $path = 'C:\deploy\staging\toolkit.ps1'
        [System.IO.File]::WriteAllBytes($path, $bytes)
        "Written: $path  ($([math]::Round($bytes.Length/1KB,1)) KB)"
    } -ArgumentList (,$toolkitContent)
}

Write-Host '==> Triggering WIM rebuild on pc-deploy (WimUpdate4)...' -ForegroundColor Cyan
Invoke-Command -Session $session -ScriptBlock {
    Remove-Item 'C:\imaging-build\wim-update4.log' -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName 'WimUpdate4'
}

Write-Host '    Waiting for WIM rebuild (up to 3 min)...' -ForegroundColor DarkGray
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep 5
    $state = Invoke-Command -Session $session -ScriptBlock {
        (Get-ScheduledTask -TaskName 'WimUpdate4').State
    }
    if ($state -eq 'Ready') { break }
    $elapsed = [int]$sw.Elapsed.TotalSeconds
    Write-Host "    [$elapsed s] $state..." -ForegroundColor DarkGray
}

if ($state -ne 'Ready') {
    Write-Warning "WIM rebuild did not finish within 3 minutes. Check log on pc-deploy."
} else {
    Invoke-Command -Session $session -ScriptBlock {
        Get-Content 'C:\imaging-build\wim-update4.log' -Tail 4 -ErrorAction SilentlyContinue
    } | ForEach-Object { Write-Host "    $_" }
    Write-Host '    WIM rebuild complete.' -ForegroundColor Green
}

Write-Host '==> Scrubbing credential file from deploy share...' -ForegroundColor Cyan
Invoke-Command -Session $session -ScriptBlock {
    $path    = 'C:\deploy\staging\deploy-boot.ps1'
    $content = Get-Content $path -Raw
    $scrubbed = $content -replace "(?m)(\`$DeployPass\s*=\s*)'[^']*'", '$1''##WINPE_PASS##'''
    [System.IO.File]::WriteAllText($path, $scrubbed, [System.Text.UTF8Encoding]::new($false))
    "Scrubbed $path"
}
Remove-PSSession $session

if ($CopyToUsb) {
    Write-Host '==> Copying boot.wim to USB (D:\sources\boot.wim)...' -ForegroundColor Cyan
    if (-not (Test-Path 'D:\sources')) {
        Write-Warning "D:\sources not found -- is the USB drive mounted as D:?"
    } else {
        net use "\\$DeployServer\winpemedia$" /delete 2>$null
        net use "\\$DeployServer\winpemedia$" /persistent:no
        Copy-Item "\\$DeployServer\winpemedia$\sources\boot.wim" 'D:\sources\boot.wim' -Force
        $sz = [math]::Round((Get-Item 'D:\sources\boot.wim').Length/1MB)
        Write-Host "    USB updated: $sz MB" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '==> Done. junadmin credentials are baked into the WIM.' -ForegroundColor Green
Write-Host '    Boot a target machine from USB to image.'
