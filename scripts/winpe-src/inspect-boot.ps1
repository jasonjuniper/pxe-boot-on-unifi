$ErrorActionPreference='Stop'
$log='C:\WinPE-src\inspect-boot.log'
function L($m){ $m | Tee-Object -FilePath $log -Append }
try{
  Remove-Item $log -ErrorAction SilentlyContinue
  $src='C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim'; $mnt='C:\WinPE-mnt'
  $out='C:\WinPE-src\_inspect'; New-Item -ItemType Directory -Force $out,$mnt | Out-Null
  $wds=Get-Service WDSServer; $run=($wds.Status -eq 'Running')
  if($run){ Stop-Service WDSServer -Force; Start-Sleep 3 }
  Mount-WindowsImage -ImagePath $src -Index 1 -Path $mnt -ReadOnly | Out-Null
  foreach($rel in @('Windows\System32\startnet.cmd','Windows\System32\winpeshl.ini','Windows\System32\deploy-boot.ps1','deploy-boot.ps1','Windows\System32\progress.ps1')){
    $p=Join-Path $mnt $rel
    if(Test-Path $p){ Copy-Item $p (Join-Path $out (Split-Path $rel -Leaf)) -Force; L ("COPIED "+$rel) }
  }
  # also search the whole image root + Windows for any *boot*.ps1 / *.cmd at top levels
  $found = Get-ChildItem $mnt -Recurse -Include 'deploy-boot.ps1','startnet.cmd','winpeshl.ini' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
  L ("FOUND: "+($found -join ' | '))
  Dismount-WindowsImage -Path $mnt -Discard | Out-Null
  if($run){ Start-Service WDSServer }
  L ("WDS="+(Get-Service WDSServer).Status+" DONE")
}catch{ L ('ERR: '+$_.Exception.Message); try{Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard -EA SilentlyContinue|Out-Null}catch{}; try{Start-Service WDSServer -EA SilentlyContinue}catch{} }
