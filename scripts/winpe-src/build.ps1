$log="C:\WinPE-src\build.log"
function Log($m){ "$(Get-Date -Format o)  $m" | Out-File $log -Append -Encoding utf8 }
$oc="C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
$mnt="C:\WinPE-mnt"; $base="C:\WinPE-src\winre-base.wim"; $work="C:\WinPE-src\winpe-deploy.wim"
function AddPkg($name){ try { Add-WindowsPackage -Path $mnt -PackagePath (Join-Path $oc $name) -ErrorAction Stop | Out-Null; Log ("  +OC " + $name) } catch { Log ("  !OC " + $name + " : " + $_.Exception.Message) } }
try {
  Log "START build"
  Copy-Item $base $work -Force
  New-Item -ItemType Directory -Force -Path $mnt | Out-Null
  Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $mnt } | ForEach-Object { Dismount-WindowsImage -Path $mnt -Discard -ErrorAction SilentlyContinue }
  Log "Mounting work WIM..."
  Mount-WindowsImage -ImagePath $work -Index 1 -Path $mnt | Out-Null
  Log "Adding OCs (NetFx, PowerShell, DismCmdlets + en-us)..."
  AddPkg "WinPE-NetFx.cab"; AddPkg "en-us\WinPE-NetFx_en-us.cab"
  AddPkg "WinPE-PowerShell.cab"; AddPkg "en-us\WinPE-PowerShell_en-us.cab"
  AddPkg "WinPE-DismCmdlets.cab"; AddPkg "en-us\WinPE-DismCmdlets_en-us.cab"
  Log ("powershell.exe now present: " + (Test-Path "$mnt\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"))
  # Drop WinRE recovery shell so it boots to startnet.cmd
  if(Test-Path "$mnt\Windows\System32\winpeshl.ini"){ Remove-Item "$mnt\Windows\System32\winpeshl.ini" -Force; Log "removed winpeshl.ini (WinRE shell)" }
  # Bake deploy scripts
  Copy-Item 'C:\deploy\scripts\winpe\deploy-boot.ps1' "$mnt\Windows\System32\deploy-boot.ps1" -Force
  Copy-Item 'C:\deploy\scripts\winpe\toolkit.ps1' "$mnt\Windows\System32\toolkit.ps1" -Force
  if(Test-Path 'C:\deploy\scripts\winpe\deploy-screen.ps1'){ Copy-Item 'C:\deploy\scripts\winpe\deploy-screen.ps1' "$mnt\deploy-screen.ps1" -Force; Log 'baked deploy-screen.ps1 (WPF)' }
  if(Test-Path 'C:\deploy\scripts\winpe\brand-fonts'){ New-Item -ItemType Directory -Force "$mnt\brand-fonts" | Out-Null; Copy-Item 'C:\deploy\scripts\winpe\brand-fonts\*' "$mnt\brand-fonts\" -Recurse -Force; Log 'baked brand-fonts' }
  $startnet = @"
@echo off
echo.
echo   Juniper Design - PC Deployment System (patched WinPE)
echo.
wpeinit
:: --- SSH server (best-effort, non-blocking) ---
if exist X:\Windows\System32\OpenSSH\sshd.exe (
  net user Administrator /active:yes >nul 2>&1
  if not exist X:\ProgramData\ssh mkdir X:\ProgramData\ssh >nul 2>&1
  X:\Windows\System32\OpenSSH\ssh-keygen.exe -A >nul 2>&1
  icacls X:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "BUILTIN\Administrators:F" "NT AUTHORITY\SYSTEM:F" >nul 2>&1
  start "" X:\Windows\System32\OpenSSH\sshd.exe
)
echo  Starting deployment bootstrap...
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Windows\System32\deploy-boot.ps1
echo  Press any key to reboot...
pause > nul
wpeutil reboot
"@
  Set-Content "$mnt\Windows\System32\startnet.cmd" -Value $startnet -Encoding Ascii
  Log "baked startnet.cmd + deploy-boot.ps1 + toolkit.ps1"
  # --- Bake OpenSSH server (best-effort remote access, key auth) ---
  $sshDst = "$mnt\Windows\System32\OpenSSH"
  New-Item -ItemType Directory -Force -Path $sshDst | Out-Null
  Copy-Item 'C:\Windows\System32\OpenSSH\*' $sshDst -Recurse -Force
  New-Item -ItemType Directory -Force -Path "$mnt\ProgramData\ssh" | Out-Null
  Copy-Item 'C:\WinPE-src\ssh\ssh_host_ed25519_key' "$mnt\ProgramData\ssh\ssh_host_ed25519_key" -Force
  Copy-Item 'C:\WinPE-src\ssh\ssh_host_ed25519_key.pub' "$mnt\ProgramData\ssh\ssh_host_ed25519_key.pub" -Force
  Copy-Item 'C:\WinPE-src\ssh\administrators_authorized_keys' "$mnt\ProgramData\ssh\administrators_authorized_keys" -Force
  Copy-Item 'C:\WinPE-src\ssh\sshd_config' "$mnt\ProgramData\ssh\sshd_config" -Force
  Log "baked OpenSSH + host key + authorized_keys + sshd_config"
  Log "Committing (unmount /save)..."
  Dismount-WindowsImage -Path $mnt -Save | Out-Null
  Log "Exporting (compress)..."
  Export-WindowsImage -SourceImagePath $work -SourceIndex 1 -DestinationImagePath 'C:\WinPE-src\winpe-deploy-final.wim' -CompressionType max | Out-Null
  $f=Get-Item 'C:\WinPE-src\winpe-deploy-final.wim'
  Log ("FINAL: " + $f.Name + " " + [math]::Round($f.Length/1MB,1) + " MB")
  Log "DONE build"
} catch { Log ("ERROR: " + $_.Exception.Message); try { Dismount-WindowsImage -Path $mnt -Discard } catch {} }
