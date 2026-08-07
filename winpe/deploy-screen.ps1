# deploy-screen.ps1 - native WPF branded imaging screen for WinPE (no browser).
# Reproduces the Juniper design system screen: navy chrome, Google Sans /
# Source Serif 4 / Roboto Mono, framing lines, wordmark, 14 phase ticks. Tails
# X:\deploy_log.txt (same file deploy.ps1's Write-DeployLog appends) to advance.
# Requires WinPE-NetFx + WinPE-PowerShell (already baked in). Fonts are loaded as
# PRIVATE fonts from a folder - no install/registry needed.
#
# Launched by deploy-boot.ps1 while deploy.ps1 runs hidden and writes the log.
param(
    [string]$LogPath   = 'X:\deploy_log.txt',
    [string]$FontDir   = 'X:\brand-fonts',
    [string]$Wordmark  = 'X:\brand-fonts\wordmark.pathdata',
    [int]   $DeployPid = 0,
    [switch]$Validate,          # off-screen render to PNG (dev pre-flight); no window
    [string]$Shot = 'shot.png', # output PNG path for -Validate
    [int]   $ShotStep = 10      # phase index to render in the shot
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- private font family references (folder + '#<family name>') --------------
$fb = 'file:///' + (($FontDir.TrimEnd('\','/')) -replace '\\','/')
$FAM_DISP = "$fb/#Google Sans"
$FAM_BODY = "$fb/#Source Serif 4"
$FAM_MONO = "$fb/#Roboto Mono"

# --- palette (design tokens) -------------------------------------------------
$NAVY='#1a1a2e'; $OFF='#e8e7e3'; $HAZE='#b8bdd0'; $ACCENT='#6e8cff'
$LINE='#4DE8E7E3'; $WARNB='#b06000'; $WARNT='#e0b870'; $WARNBG='#1FD08C2D'

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" WindowState="Maximized" ResizeMode="NoResize"
        Background="$NAVY" Cursor="None" Topmost="True"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Grid Background="$NAVY">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="0.06*"/><ColumnDefinition Width="0.88*"/><ColumnDefinition Width="0.06*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="0.06*"/><RowDefinition Height="0.88*"/><RowDefinition Height="0.06*"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="1" Grid.Column="1" BorderBrush="$LINE" BorderThickness="1"/>
    <DockPanel Grid.Row="1" Grid.Column="1" Margin="40,28,40,24">
      <Grid DockPanel.Dock="Bottom" Margin="0,24,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="footMachine" Grid.Column="0" HorizontalAlignment="Left"  Foreground="$HAZE"/>
        <TextBlock x:Name="footSerial"  Grid.Column="1" HorizontalAlignment="Left"  Foreground="$HAZE"/>
        <TextBlock x:Name="footImage"   Grid.Column="2" HorizontalAlignment="Left"  Foreground="$HAZE"/>
        <TextBlock x:Name="footSupport" Grid.Column="3" HorizontalAlignment="Right" Foreground="$HAZE"/>
      </Grid>
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="700">
        <Viewbox Width="190" HorizontalAlignment="Center" Margin="0,0,0,26">
          <Canvas x:Name="markCanvas" Width="1451.88" Height="541.35">
            <Path x:Name="wordmark" Fill="$OFF"/>
          </Canvas>
        </Viewbox>
        <TextBlock x:Name="tagline" HorizontalAlignment="Center" Foreground="$HAZE" FontSize="13" Margin="0,0,0,30"
                   Text="DESIGNED IN CONNECTICUT.  MADE IN CONNECTICUT."/>
        <TextBlock x:Name="headline" HorizontalAlignment="Center" Foreground="$OFF" FontSize="46"
                   TextAlignment="Center" Text="Setting up this computer"/>
        <TextBlock x:Name="sub" HorizontalAlignment="Center" Foreground="$HAZE" FontSize="17"
                   TextAlignment="Center" TextWrapping="Wrap" MaxWidth="560" Margin="0,14,0,34"
                   Text="This takes about 40 minutes. The machine will restart a few times on its own - you can leave it."/>
        <UniformGrid x:Name="ticks" Rows="1" Width="680" Height="3" HorizontalAlignment="Center" Margin="0,0,0,14"/>
        <Grid Width="680" HorizontalAlignment="Center" Margin="0,0,0,8">
          <TextBlock x:Name="phase" HorizontalAlignment="Left"  Foreground="$HAZE" FontSize="12" Text="WINPE"/>
          <TextBlock x:Name="pct"   HorizontalAlignment="Right" Foreground="$OFF"  FontSize="12" Text="0%"/>
        </Grid>
        <Grid x:Name="barTrack" Width="680" Height="2" HorizontalAlignment="Center" Background="$LINE">
          <Rectangle x:Name="fill" HorizontalAlignment="Left" Width="0" Fill="$OFF"/>
        </Grid>
        <TextBlock x:Name="step" HorizontalAlignment="Center" Foreground="$HAZE" FontSize="13" Margin="0,14,0,0" Text="Starting..."/>
        <Border x:Name="warnbox" Visibility="Collapsed" BorderBrush="$WARNB" BorderThickness="1" Background="$WARNBG"
                Padding="14,8" Margin="0,18,0,0" HorizontalAlignment="Center" MaxWidth="560">
          <TextBlock x:Name="warntext" Foreground="$WARNT" FontSize="13" TextWrapping="Wrap"/>
        </Border>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
"@

$win = [System.Windows.Markup.XamlReader]::Parse($xaml)
function E($n){ $win.FindName($n) }

# --- fonts (private) ---------------------------------------------------------
$disp = New-Object System.Windows.Media.FontFamily($FAM_DISP)
$body = New-Object System.Windows.Media.FontFamily($FAM_BODY)
$mono = New-Object System.Windows.Media.FontFamily($FAM_MONO)
$win.FontFamily = $disp
foreach($n in 'phase','pct','step','footMachine','footSerial','footImage','footSupport','warntext'){ (E $n).FontFamily = $mono }
(E 'sub').FontFamily = $body
(E 'tagline').FontFamily = $disp

# --- wordmark geometry -------------------------------------------------------
try { if(Test-Path $Wordmark){ (E 'wordmark').Data = [System.Windows.Media.Geometry]::Parse((Get-Content $Wordmark -Raw)) } } catch {}
(E 'markCanvas').Opacity = 0.92

# --- footer spec -------------------------------------------------------------
$bc = New-Object System.Windows.Media.BrushConverter
$brHaze = $bc.ConvertFrom($HAZE)
$brOff  = $bc.ConvertFrom($OFF)
$serial = '------'
try { $s = (Get-WmiObject Win32_BIOS -EA Stop).SerialNumber; if($s){ $serial = "$s".Trim() } } catch {}
function Spec($el,$label,$val){
  $tb = E $el; $tb.Inlines.Clear()
  $r1 = New-Object System.Windows.Documents.Run(($label + '  ')); $r1.Foreground = $brHaze
  $r2 = New-Object System.Windows.Documents.Run([string]$val);    $r2.Foreground = $brOff
  $tb.Inlines.Add($r1); $tb.Inlines.Add($r2)
}
Spec 'footMachine' 'MACHINE' '--'
Spec 'footSerial'  'SERIAL'  $serial
Spec 'footImage'   'IMAGE'   'Win11-Engineering'
Spec 'footSupport' 'SUPPORT' 'x2400'

# --- phase table (mirrors deploy.ps1 Write-DeployLog lines) ------------------
$STEPS = @(
 @{ph='WinPE';       msg='Partitioning disk 0';           re='Partitioning disk'},
 @{ph='WinPE';       msg='Applying the Windows image';    re='Step: Applying .+\(DISM'},
 @{ph='WinPE';       msg='Image applied';                 re='WIM applied'},
 @{ph='WinPE';       msg='Injecting drivers';             re='Injecting drivers'},
 @{ph='WinPE';       msg='Writing unattend';              re='Writing unattend'},
 @{ph='WinPE';       msg='Staging post-install scripts';  re='Staging post-install'},
 @{ph='WinPE';       msg='Registering in inventory';      re='Registering in inventory'},
 @{ph='WinPE';       msg='Configuring UEFI boot';         re='Configuring UEFI boot'},
 @{ph='WinPE';       msg='Restarting into Windows';       re='WinPE phase complete|Restarting into Windows'},
 @{ph='Post-install';msg='Installing Windows updates';    re='PHASE START: Windows Update'},
 @{ph='Post-install';msg='Installing packages';           re='PHASE START: Install Packages'},
 @{ph='Post-install';msg='Removing preinstalled apps';    re='PHASE START: Remove Bloatware'},
 @{ph='Post-install';msg='Applying policies';             re='PHASE START:.*(Polic|MDM)'},
 @{ph='Complete';    msg='Ready to sign in';              re='All imaging phases complete|Imaging complete'}
)
$brDone = $bc.ConvertFrom($OFF)
$brNow  = $bc.ConvertFrom($ACCENT)
$brTodo = $bc.ConvertFrom($LINE)
$tickGrid = E 'ticks'
$tickRects = @()
for($i=0;$i -lt $STEPS.Count;$i++){
  $r = New-Object System.Windows.Shapes.Rectangle
  $r.Fill = $brTodo
  if($i -lt ($STEPS.Count-1)){ $r.Margin = New-Object System.Windows.Thickness(0,0,5,0) }
  [void]$tickGrid.Children.Add($r); $tickRects += $r
}
$CW = 680.0
$script:lastIdx = -2
$script:lastFail = $false
function Render($idx,$failed){
  if($idx -eq $script:lastIdx -and $failed -eq $script:lastFail){ return }
  $script:lastIdx = $idx; $script:lastFail = $failed
  if($idx -lt 0){ $ph='WinPE'; $msg='Starting...'; $pct=0 }
  else { $ph=$STEPS[$idx].ph; $msg=$STEPS[$idx].msg; $pct=[int][math]::Round(100.0 * ($idx + 1) / $STEPS.Count) }
  $w = $CW * $pct / 100.0
  if($w -lt 0){ $w = 0.0 } elseif($w -gt $CW){ $w = $CW }
  (E 'phase').Text = $ph.ToUpper()
  (E 'step').Text  = $msg
  (E 'pct').Text   = "$pct%"
  (E 'fill').Width = [double]$w
  for($n=0;$n -lt $tickRects.Count;$n++){
    if($n -lt $idx){ $tickRects[$n].Fill=$brDone }
    elseif($n -eq $idx){ $tickRects[$n].Fill=$brNow }
    else{ $tickRects[$n].Fill=$brTodo }
  }
  $done = ($idx -eq ($STEPS.Count-1))
  (E 'headline').Text = $(if($done){'This computer is ready'} else {'Setting up this computer'})
  (E 'sub').Text = $(if($done){'Sign in with your Juniper account to finish.'} else {'This takes about 40 minutes. The machine will restart a few times on its own - you can leave it.'})
  if($failed){ (E 'warntext').Text='A step reported a problem. Imaging continues; a technician will review the log.'; (E 'warnbox').Visibility='Visible' }
  else { (E 'warnbox').Visibility='Collapsed' }
}
function Scan($text){
  $idx=-1; $failed=$false
  foreach($ln in ($text -split "`r?`n")){
    if($ln -match 'PHASE END:.*FAILED|\[ERROR\]'){ $failed=$true }
    for($s=$idx+1;$s -lt $STEPS.Count;$s++){ if($ln -match $STEPS[$s].re){ $idx=$s; $failed=$false; break } }
  }
  Render $idx $failed
}
Render -1 $false

# --- poll timer --------------------------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1200)
$timer.Add_Tick({
  try { if(Test-Path $LogPath){ $t=[System.IO.File]::ReadAllText($LogPath); if($t){ Scan $t } } } catch {}
  if($DeployPid -gt 0){
    $p = Get-Process -Id $DeployPid -EA SilentlyContinue
    if(-not $p -and $script:lastIdx -lt ($STEPS.Count-1)){ $timer.Stop(); $win.Close() }
  }
})
# --- dev pre-flight: off-screen render to PNG, no window --------------------
if($Validate){
  $root = $win.Content; $win.Content = $null
  $W=1280; $H=720
  $root.Measure((New-Object System.Windows.Size($W,$H)))
  $root.Arrange((New-Object System.Windows.Rect(0,0,$W,$H)))
  $root.UpdateLayout()
  Render $ShotStep $false
  $root.UpdateLayout()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W,$H,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($root)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [System.IO.File]::Open($Shot,'Create'); $enc.Save($fs); $fs.Close()
  Write-Output "VALIDATE OK -> $Shot"
  return
}

$win.Add_SourceInitialized({ $timer.Start() })
$win.Add_KeyDown({ if($_.Key -eq 'Escape'){ $win.Close() } })
[void]$win.ShowDialog()
