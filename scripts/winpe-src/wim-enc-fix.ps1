$ErrorActionPreference="Stop"
$log="C:\WinPE-src\wim-enc-fix.log"
"start $(Get-Date -f o)" | Set-Content $log
try{
  $src="C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim"; $mnt="C:\WinPE-mnt"
  New-Item -ItemType Directory -Force $mnt | Out-Null
  $wds=Get-Service WDSServer; $run=($wds.Status -eq "Running")
  if($run){ Stop-Service WDSServer -Force; Start-Sleep 4 }
  Mount-WindowsImage -ImagePath $src -Index 1 -Path $mnt | Out-Null
  "mounted" | Add-Content $log
  & "C:\inventory\venv\Scripts\python.exe" "C:\WinPE-src\wim-enc-fix.py" 2>&1 | Add-Content $log
  Dismount-WindowsImage -Path $mnt -Save | Out-Null
  "dismount-saved; wim=$((Get-Item $src).Length)" | Add-Content $log
  if($run){ Start-Service WDSServer }
  "WDS=$((Get-Service WDSServer).Status) DONE" | Add-Content $log
}catch{ "ERR: $($_.Exception.Message)" | Add-Content $log; try{Dismount-WindowsImage -Path "C:\WinPE-mnt" -Discard -EA SilentlyContinue|Out-Null}catch{}; try{Start-Service WDSServer -EA SilentlyContinue}catch{} }
