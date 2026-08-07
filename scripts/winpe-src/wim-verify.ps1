$ErrorActionPreference="Stop"
$log="C:\WinPE-src\wim-verify.log"; "start" | Set-Content $log
try{
  $src="C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim"; $mnt="C:\WinPE-mnt"
  New-Item -ItemType Directory -Force $mnt | Out-Null
  $wds=Get-Service WDSServer; $run=($wds.Status -eq "Running")
  if($run){ Stop-Service WDSServer -Force; Start-Sleep 4 }
  Mount-WindowsImage -ImagePath $src -Index 1 -Path $mnt -ReadOnly | Out-Null
  $tk="$mnt\Windows\System32\toolkit.ps1"
  $b=[byte[]](Get-Content $tk -Encoding Byte -TotalCount 3)
  $bom=($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
  $errs=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile($tk,[ref]$null,[ref]$errs)
  "toolkit.ps1 BOM=$bom parseErrors=$(@($errs).Count)" | Add-Content $log
  Dismount-WindowsImage -Path $mnt -Discard | Out-Null
  if($run){ Start-Service WDSServer }
  "WDS=$((Get-Service WDSServer).Status) DONE" | Add-Content $log
}catch{ "ERR: $($_.Exception.Message)" | Add-Content $log; try{Dismount-WindowsImage -Path "C:\WinPE-mnt" -Discard -EA SilentlyContinue|Out-Null}catch{}; try{Start-Service WDSServer -EA SilentlyContinue}catch{} }
