# provision-status.ps1 - Juniper Provisioning Status / Lockout Screen
# ---------------------------------------------------------------------------
# A fullscreen, borderless, always-on-top WPF window shown to the auto-logged-in
# provisioning user (junadmin) DURING post-image setup.  It is launched as that
# user's Winlogon SHELL (instead of explorer.exe) by orchestrator.ps1's kiosk
# mode, so the end user sees ONLY this screen - no desktop, no taskbar, no Start
# menu = locked out until imaging finishes.
#
# It polls C:\ProgramData\JuniperSetup\progress.json (written by orchestrator.ps1)
# about every 1.5s and updates a determinate progress bar + status text.
# When state == 'done' it shows "Almost finished - restarting" and exits cleanly
# (the orchestrator performs the actual reboot into the normal login screen).
#
# Designed to be relaunched fresh on every provisioning reboot.  ASCII-safe:
# no smart quotes, em dashes, or BOM.
#
# Break-glass for a stuck machine (tech only):
#   Press Ctrl+Shift+Alt+F12 to drop straight to explorer.exe on THIS session.
#   (This only affects the running kiosk window; the orchestrator still owns
#    autologon teardown.  For a full reset, drop the break-glass.txt flag - see
#    CLAUDE.md - and reboot.)

$ErrorActionPreference = 'SilentlyContinue'

$SetupRoot    = 'C:\ProgramData\JuniperSetup'
$ProgressFile = "$SetupRoot\progress.json"
$StartedUtc   = (Get-Date).ToUniversalTime()

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---- XAML ------------------------------------------------------------------
# Navy Juniper background, white text, centered content, determinate bar.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="#0B1F3A"
        Cursor="None" AllowsTransparency="False">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" Width="780">

      <TextBlock x:Name="Wordmark" Text="JUNIPER DESIGN"
                 FontFamily="Segoe UI" FontSize="22" FontWeight="Bold"
                 Foreground="#7FA8D9" HorizontalAlignment="Center"
                 Margin="0,0,0,28" />

      <TextBlock Text="Setting up this PC"
                 FontFamily="Segoe UI Light" FontSize="48" FontWeight="Light"
                 Foreground="White" HorizontalAlignment="Center"
                 Margin="0,0,0,16" />

      <TextBlock x:Name="PhaseLabel" Text="Preparing this PC"
                 FontFamily="Segoe UI" FontSize="24"
                 Foreground="#DDE6F2" HorizontalAlignment="Center"
                 TextAlignment="Center" Margin="0,0,0,6" />

      <TextBlock x:Name="StepMessage" Text=""
                 FontFamily="Segoe UI" FontSize="16"
                 Foreground="#9FB6D4" HorizontalAlignment="Center"
                 TextAlignment="Center" Margin="0,0,0,28" TextWrapping="Wrap" />

      <Border CornerRadius="6" Background="#16294A" Padding="3" Margin="0,0,0,10">
        <ProgressBar x:Name="Bar" Height="22" Minimum="0" Maximum="100" Value="0"
                     Foreground="#3F8EDC" Background="Transparent"
                     BorderThickness="0" />
      </Border>

      <Grid Margin="0,0,0,30">
        <TextBlock x:Name="PercentText" Text="0%"
                   FontFamily="Segoe UI" FontSize="15" Foreground="#9FB6D4"
                   HorizontalAlignment="Left" />
        <TextBlock x:Name="StepCounter" Text=""
                   FontFamily="Segoe UI" FontSize="15" Foreground="#9FB6D4"
                   HorizontalAlignment="Right" />
      </Grid>

      <TextBlock Text="Please keep this PC plugged in and powered on. It will restart a few times and finish automatically."
                 FontFamily="Segoe UI" FontSize="15"
                 Foreground="#9FB6D4" HorizontalAlignment="Center"
                 TextAlignment="Center" TextWrapping="Wrap" Margin="0,0,0,8" />

      <TextBlock x:Name="ElapsedText" Text=""
                 FontFamily="Segoe UI" FontSize="13"
                 Foreground="#5E7596" HorizontalAlignment="Center"
                 Margin="0,6,0,0" />
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

$PhaseLabel  = $win.FindName('PhaseLabel')
$StepMessage = $win.FindName('StepMessage')
$Bar         = $win.FindName('Bar')
$PercentText = $win.FindName('PercentText')
$StepCounter = $win.FindName('StepCounter')
$ElapsedText = $win.FindName('ElapsedText')

# ---- Lockout behavior ------------------------------------------------------
# Swallow Alt+F4 and most keys so the screen can't be dismissed.  Allow a single
# hidden break-glass combo (Ctrl+Shift+Alt+F12) to drop to explorer for a tech.
$win.Add_Closing({
    param($s,$e)
    if (-not $script:AllowClose) { $e.Cancel = $true }
})

$win.Add_KeyDown({
    param($s,$e)
    # Break-glass: Ctrl+Shift+Alt+F12 -> launch explorer on this session and exit.
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    if ($e.Key -eq [System.Windows.Input.Key]::F12 -and
        ($mods -band [System.Windows.Input.ModifierKeys]::Control) -and
        ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -and
        ($mods -band [System.Windows.Input.ModifierKeys]::Alt)) {
        try { Start-Process 'explorer.exe' } catch {}
        $script:AllowClose = $true
        $win.Close()
        return
    }
    # Otherwise swallow the key (no Alt+F4, no Tab-out, no nothing).
    $e.Handled = $true
})

# Keep ourselves topmost if something steals focus.
$win.Add_Deactivated({ $win.Topmost = $true; $win.Activate() })

# ---- Progress polling ------------------------------------------------------
function Read-Progress {
    if (-not (Test-Path $ProgressFile)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($ProgressFile)
            if ($raw) { return ($raw | ConvertFrom-Json) }
        } catch { Start-Sleep -Milliseconds 120 }
    }
    return $null
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1500)
$timer.Add_Tick({
    $p = Read-Progress

    # Elapsed time since this screen opened.
    $elapsed = [int](New-TimeSpan -Start $StartedUtc -End (Get-Date).ToUniversalTime()).TotalMinutes
    $ElapsedText.Text = "Elapsed: $elapsed min"

    if (-not $p) {
        $PhaseLabel.Text  = 'Preparing this PC'
        $StepMessage.Text = 'Starting setup'
        return
    }

    $state = "$($p.state)"

    if ($state -eq 'error') {
        $PhaseLabel.Text  = 'Setup hit a problem'
        $StepMessage.Text = if ($p.stepMessage) { "$($p.stepMessage)" } else { 'A technician has been notified. Please contact IT.' }
        $Bar.Foreground   = '#D9534F'
        return
    }

    if ($p.phaseLabel)  { $PhaseLabel.Text  = "$($p.phaseLabel)" }
    if ($null -ne $p.stepMessage) { $StepMessage.Text = "$($p.stepMessage)" }

    $pct = 0
    try { $pct = [int]$p.overallPercent } catch {}
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
    $Bar.Value = $pct
    $PercentText.Text = "$pct%"

    if ($p.phaseTotal -and [int]$p.phaseTotal -gt 0 -and [int]$p.phaseIndex -ge 1) {
        $StepCounter.Text = "Step $([int]$p.phaseIndex) of $([int]$p.phaseTotal)"
    } else {
        $StepCounter.Text = ''
    }

    if ($state -eq 'rebooting') {
        $StepMessage.Text = 'Restarting to continue setup...'
    }

    if ($state -eq 'done') {
        $PhaseLabel.Text  = 'Almost finished - restarting'
        $StepMessage.Text = 'This PC will restart and be ready to use.'
        $Bar.Value        = 100
        $PercentText.Text = '100%'
        # Let the orchestrator perform the reboot; exit our kiosk shell cleanly.
        $timer.Stop()
        $script:AllowClose = $true
        $win.Close()
    }
})

$win.Add_Loaded({
    $win.Topmost = $true
    $win.Activate()
    $timer.Start()
})

# ---- Show ------------------------------------------------------------------
$script:AllowClose = $false
[void]$win.ShowDialog()
