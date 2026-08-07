$ErrorActionPreference='Stop'
$log='C:\WinPE-src\promote.log'
function Log($m){ "$(Get-Date -f o)  $m" | Out-File $log -Append -Encoding utf8 }
Set-Content $log ''
try{
 $final='C:\WinPE-src\winpe-edge-final.wim'
 $srcUsb='C:\WinPE-src\winpe-deploy-final.wim'
 $live='C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim'
 Log 'START promote'
 $h=(Get-FileHash $final -Algorithm SHA256).Hash
 Log ("final sha256=$h")
 if((Test-Path $srcUsb) -and -not (Test-Path "$srcUsb.bak-aug4build")){ Copy-Item $srcUsb "$srcUsb.bak-aug4build" -Force; Log 'backed up prior WinPE-src final -> .bak-aug4build' }
 Copy-Item $final $srcUsb -Force
 $h2=(Get-FileHash $srcUsb -Algorithm SHA256).Hash
 Log ("USB-path WinPE-src updated hashMatch=" + ($h -eq $h2))
 $wds=Get-Service WDSServer -EA SilentlyContinue; $run=($wds -and $wds.Status -eq 'Running')
 if($run){ Stop-Service WDSServer -Force; Start-Sleep 4; Log 'WDS stopped' }
 Copy-Item $final $live -Force
 $h3=(Get-FileHash $live -Algorithm SHA256).Hash
 Log ("PXE RemoteInstall updated hashMatch=" + ($h -eq $h3))
 if($run){ Start-Service WDSServer; Log ('WDS=' + (Get-Service WDSServer).Status) }
 Remove-Item 'C:\WinPE-src\winpe-edge-work.wim' -Force -EA SilentlyContinue
 Log 'removed winpe-edge-work.wim'
 $free=[math]::Round((Get-PSDrive C).Free/1GB,1); Log ("C: free=$free GB")
 Log 'DONE promote'
}catch{ Log ('ERROR: ' + $_.Exception.Message); try{ if((Get-Service WDSServer -EA SilentlyContinue).Status -ne 'Running'){Start-Service WDSServer} }catch{} }