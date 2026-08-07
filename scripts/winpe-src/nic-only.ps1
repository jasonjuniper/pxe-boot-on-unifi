$ErrorActionPreference='Stop'
$log='C:\WinPE-src\nic-only.log'
function L($m){ ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'),$m) | Tee-Object -FilePath $log -Append }
try{
  Remove-Item $log -EA SilentlyContinue
  $src='C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim'; $mnt='C:\WinPE-mnt'
  New-Item -ItemType Directory -Force $mnt | Out-Null
  L ("START. wim before = "+((Get-Item $src).Length))
  $wds=Get-Service WDSServer; $run=($wds.Status -eq 'Running')
  if($run){ L 'Stop WDS'; Stop-Service WDSServer -Force; Start-Sleep 4 }
  Mount-WindowsImage -ImagePath $src -Index 1 -Path $mnt | Out-Null
  $adds=@(
    'C:\deploy\drivers\_winpe-drivers\realtek-rt640x64-signed',
    'C:\deploy\drivers\_winpe-drivers\asus-board\e1r68x64.inf_amd64_785b9f7575fc9ab7',
    'C:\deploy\drivers\_winpe-drivers\asus-board\e1r68x64.inf_amd64_8175f39383f631b7'
  )
  foreach($d in $adds){ L ("Add "+(Split-Path $d -Leaf)); Add-WindowsDriver -Path $mnt -Driver $d | Out-Null }
  $net=Get-WindowsDriver -Path $mnt | Where-Object ClassName -eq 'Net'
  L ("Net drivers now = "+$net.Count+" : "+(( $net | ForEach-Object { Split-Path $_.OriginalFileName -Leaf }) -join ','))
  $rt=[bool]($net|?{$_.OriginalFileName -match 'ws640x64|rt640x64'}); $i2=[bool]($net|?{$_.OriginalFileName -match 'e1r68x64'})
  L ("Realtek GbE present="+$rt+"  Intel I211 present="+$i2)
  Dismount-WindowsImage -Path $mnt -Save | Out-Null
  L ("wim after = "+((Get-Item $src).Length))
  if($run){ Start-Service WDSServer }
  L ("WDS="+(Get-Service WDSServer).Status+"  DONE OK")
}catch{ L ('ERR: '+$_.Exception.Message); try{Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard -EA SilentlyContinue|Out-Null}catch{}; try{Start-Service WDSServer -EA SilentlyContinue}catch{} }
