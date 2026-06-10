# 07-remove-bloatware.ps1
# Removes unwanted pre-installed apps and disables junk Windows 10/11 features
# on a freshly imaged PC.
#
# Customize the $AppxToRemove and $FeaturesToDisable lists for your environment.
#
# USAGE: .\07-remove-bloatware.ps1
#        .\07-remove-bloatware.ps1 -DryRun

param([switch]$DryRun)

$ErrorActionPreference = 'SilentlyContinue'   # removal errors are non-fatal

# ---------------------------------------------------------------------------
# APPX PACKAGES TO REMOVE (provisioned + per-user)
# Use: Get-AppxPackage | Select-Object Name to find package names
# ---------------------------------------------------------------------------
$AppxToRemove = @(
    # Microsoft bloat (Win10 + Win11)
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.People',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',         # Phone Link (Win10 name)
    'Microsoft.YourPhoneApp',      # Phone Link (Win11 name)
    'Microsoft.ZuneMusic',         # Media Player (old)
    'Microsoft.ZuneVideo',         # Movies & TV

    # Windows 11 specific
    'MicrosoftTeams',              # Teams (personal) — preinstalled on Win11
    'Microsoft.Teams',             # Teams (personal) — alternate package name
    'Microsoft.MicrosoftTeams',    # Teams — another variant
    'Microsoft.Cortana',           # Cortana — can be removed on Win11
    'Clipchamp.Clipchamp',         # Clipchamp video editor
    'Microsoft.Windows.DevHome',   # Dev Home (Win11 23H2+)
    'Microsoft.WindowsCommunicationsApps', # Mail and Calendar
    'Microsoft.OutlookForWindows', # New Outlook (if preinstalled)

    # OEM / third-party (add as needed)
    # 'CandyCrush*',
    # 'king.com*',
    # 'Dell*',
    # 'HP*',
)

# ---------------------------------------------------------------------------
# OPTIONAL WINDOWS FEATURES TO DISABLE
# Use: Get-WindowsOptionalFeature -Online | Where-Object State -eq Enabled
# ---------------------------------------------------------------------------
$FeaturesToDisable = @(
    'WindowsMediaPlayer',
    'Internet-Explorer-Optional-amd64',  # Win10 only; absent on Win11 (silently skipped)
    # 'WorkFolders-Client',
)

# ---------------------------------------------------------------------------
# SCHEDULED TASKS TO DISABLE (consumer / telemetry junk)
# ---------------------------------------------------------------------------
$TasksToDisable = @(
    # These exist on Win10 and may exist on Win11 — script skips silently if absent
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    # Win11 specific telemetry tasks
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
)

# ---------------------------------------------------------------------------

Write-Host '==> Removing AppX packages...' -ForegroundColor Cyan
foreach ($name in $AppxToRemove) {
    $pkgs = Get-AppxPackage -Name $name -AllUsers 2>$null
    $prov  = Get-AppxProvisionedPackage -Online 2>$null | Where-Object { $_.DisplayName -like $name }
    if (-not $pkgs -and -not $prov) { continue }
    Write-Host "  Remove: $name" -ForegroundColor Cyan
    if (-not $DryRun) {
        $pkgs | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        $prov  | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '==> Disabling optional Windows features...' -ForegroundColor Cyan
foreach ($feat in $FeaturesToDisable) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction SilentlyContinue
    if (-not $f -or $f.State -ne 'Enabled') { continue }
    Write-Host "  Disable: $feat" -ForegroundColor Cyan
    if (-not $DryRun) {
        Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '==> Disabling telemetry scheduled tasks...' -ForegroundColor Cyan
foreach ($task in $TasksToDisable) {
    $t = Get-ScheduledTask -TaskPath (Split-Path $task -Parent) `
                           -TaskName  (Split-Path $task -Leaf) -ErrorAction SilentlyContinue
    if (-not $t -or $t.State -eq 'Disabled') { continue }
    Write-Host "  Disable: $task" -ForegroundColor Cyan
    if (-not $DryRun) { Disable-ScheduledTask -TaskPath (Split-Path $task -Parent) -TaskName (Split-Path $task -Leaf) -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '==> Disabling consumer experience / ads / widgets...' -ForegroundColor Cyan
if (-not $DryRun) {
    $regPaths = @{
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' = @{
            'DisableWindowsConsumerFeatures' = 1
        }
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' = @{
            'SubscribedContent-338389Enabled' = 0   # Tips
            'SubscribedContent-338388Enabled' = 0   # Start suggestions
            'SystemPaneSuggestionsEnabled'    = 0
            'SubscribedContent-310093Enabled' = 0   # "Suggested" apps
            'SoftLandingEnabled'             = 0   # Spotlight lock screen
        }
        # Win11: disable Widgets (TaskbarDa) and Chat (Teams consumer)
        'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' = @{
            'AllowNewsAndInterests' = 0             # Widgets
        }
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' = @{
            'TaskbarDa'  = 0                        # Hide Widgets button from taskbar
            'TaskbarMn'  = 0                        # Hide Chat (Teams) button from taskbar
        }
        # Win11: disable "Recommended" section in Start Menu
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' = @{
            'HideRecommendedSection' = 1
        }
    }
    foreach ($path in $regPaths.Keys) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        foreach ($name in $regPaths[$path].Keys) {
            Set-ItemProperty -Path $path -Name $name -Value $regPaths[$path][$name] -Type DWord -Force
        }
    }
}

Write-Host ''
Write-Host '==> Bloatware removal complete.' -ForegroundColor Green
if ($DryRun) { Write-Host '    (Dry run - nothing was actually changed.)' -ForegroundColor Yellow }
Write-Host '    A reboot is recommended to finalize feature changes.' -ForegroundColor Yellow
