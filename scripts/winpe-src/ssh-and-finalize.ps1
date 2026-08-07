$ErrorActionPreference='Stop'
$log='C:\WinPE-src\ssh-final.log'
function Log($m){ "$(Get-Date -f o)  $m" | Out-File $log -Append -Encoding utf8 }
Set-Content $log ''
try{
 $work='C:\WinPE-src\winpe-edge-work.wim'
 $final='C:\WinPE-src\winpe-edge-final.wim'
 $mnt='C:\WinPE-mnt'
 Log 'START ssh-final'
 New-Item -ItemType Directory -Force $mnt | Out-Null
 Get-WindowsImage -Mounted -EA SilentlyContinue | ? { $_.Path -eq $mnt } | % { Dismount-WindowsImage -Path $mnt -Discard -EA SilentlyContinue }
 Mount-WindowsImage -ImagePath $work -Index 1 -Path $mnt | Out-Null
 Log 'mounted work'
 $sshDst="$mnt\Windows\System32\OpenSSH"; New-Item -ItemType Directory -Force $sshDst | Out-Null
 Copy-Item 'C:\Windows\System32\OpenSSH\*' $sshDst -Recurse -Force
 New-Item -ItemType Directory -Force "$mnt\ProgramData\ssh" | Out-Null
 foreach($k in 'ssh_host_ed25519_key','ssh_host_ed25519_key.pub','administrators_authorized_keys','sshd_config'){ if(Test-Path "C:\WinPE-src\ssh\$k"){ Copy-Item "C:\WinPE-src\ssh\$k" "$mnt\ProgramData\ssh\$k" -Force } }
 Log ('OpenSSH baked; sshd.exe=' + (Test-Path "$sshDst\sshd.exe"))
 $startnet=@"
@echo off
echo.
echo   Juniper Design - PC Deployment System (patched WinPE)
echo.
wpeinit
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
 Log 'startnet.cmd updated (sshd + deploy-boot)'
 Log 'dismount /save...'
 Dismount-WindowsImage -Path $mnt -Save | Out-Null
 Log ('saved work ' + [math]::Round((Get-Item $work).Length/1MB,1) + 'MB')
 if(Test-Path $final){ Remove-Item $final -Force }
 Log 'export compress max...'
 Export-WindowsImage -SourceImagePath $work -SourceIndex 1 -DestinationImagePath $final -CompressionType max | Out-Null
 Log ('final ' + [math]::Round((Get-Item $final).Length/1MB,1) + 'MB')
 Mount-WindowsImage -ImagePath $final -Index 1 -Path $mnt -ReadOnly | Out-Null
 $ssh=Test-Path "$mnt\Windows\System32\OpenSSH\sshd.exe"; $ed=Test-Path "$mnt\edge\msedge.exe"; $sc=Test-Path "$mnt\imaging-screen.html"
 $sn=Get-Content "$mnt\Windows\System32\startnet.cmd" -Raw
 $dbc=Get-Content "$mnt\Windows\System32\deploy-boot.ps1" -Raw
 $drv=@(Get-WindowsDriver -Path $mnt -EA SilentlyContinue).Count
 Log ("VERIFY sshd=$ssh edge=$ed screen=$sc startnetHasSshd=" + [bool]($sn -match 'sshd.exe') + " deployPlaceholder=" + [bool]($dbc -match '##WINPE_PASS##') + " drivers=$drv")
 Dismount-WindowsImage -Path $mnt -Discard | Out-Null
 Log 'DONE ssh-final'
}catch{ Log ('ERROR: ' + $_.Exception.Message); try{Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard -EA SilentlyContinue|Out-Null}catch{} }