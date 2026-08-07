$ErrorActionPreference='Stop'
$log='C:\WinPE-src\wpf-bake.log'
function Log($m){ "$(Get-Date -f o)  $m" | Out-File $log -Append -Encoding utf8 }
Set-Content $log ''
try{
 $live='C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim'
 $work='C:\WinPE-src\winpe-wpf-work.wim'; $final='C:\WinPE-src\winpe-wpf-final.wim'; $mnt='C:\WinPE-mnt'
 Log 'START wpf-bake'
 $bak='C:\WinPE-src\winpe-deploy-final.wim.bak-edge'
 if(-not (Test-Path $bak)){ Copy-Item $live $bak -Force; Log "backed up current live(edge) -> $bak" }
 if(Test-Path $work){ Remove-Item $work -Force }
 Copy-Item $live $work -Force
 Log ('copied live -> work '+[math]::Round((Get-Item $work).Length/1MB,1)+'MB')
 New-Item -ItemType Directory -Force $mnt | Out-Null
 Get-WindowsImage -Mounted -EA SilentlyContinue | ? { $_.Path -eq $mnt } | % { Dismount-WindowsImage -Path $mnt -Discard -EA SilentlyContinue }
 Mount-WindowsImage -ImagePath $work -Index 1 -Path $mnt | Out-Null
 Log 'mounted'
 if(Test-Path "$mnt\edge"){ Remove-Item "$mnt\edge" -Recurse -Force; Log 'removed X:\edge' }
 if(Test-Path "$mnt\imaging-screen.html"){ Remove-Item "$mnt\imaging-screen.html" -Force; Log 'removed imaging-screen.html' }
 if(Test-Path "$mnt\edgeprofile"){ Remove-Item "$mnt\edgeprofile" -Recurse -Force -EA SilentlyContinue }
 $credf='C:\WinPE-src\deploy-boot-cred.ps1'
 if(-not (Test-Path $credf)){ throw 'missing deploy-boot-cred.ps1' }
 $c=Get-Content $credf -Raw
 if($c -match '##WINPE_PASS##'){ throw 'cred placeholder not substituted' }
 if($c -notmatch 'deploy-screen'){ throw 'cred not WPF launcher' }
 [IO.File]::WriteAllText("$mnt\Windows\System32\deploy-boot.ps1",$c,[Text.UTF8Encoding]::new($false))
 Log 'deploy-boot.ps1 (WPF) injected'
 Copy-Item 'C:\deploy\scripts\winpe\deploy-screen.ps1' "$mnt\deploy-screen.ps1" -Force
 Log 'deploy-screen.ps1 injected'
 New-Item -ItemType Directory -Force "$mnt\brand-fonts" | Out-Null
 Copy-Item 'C:\deploy\scripts\winpe\brand-fonts\*' "$mnt\brand-fonts\" -Recurse -Force
 Log ('brand-fonts injected ('+@(Get-ChildItem "$mnt\brand-fonts" -File).Count+' files)')
 Log 'dismount /save...'
 Dismount-WindowsImage -Path $mnt -Save | Out-Null
 Log ('saved work '+[math]::Round((Get-Item $work).Length/1MB,1)+'MB')
 if(Test-Path $final){ Remove-Item $final -Force }
 Log 'export compress max...'
 Export-WindowsImage -SourceImagePath $work -SourceIndex 1 -DestinationImagePath $final -CompressionType max | Out-Null
 Log ('final '+[math]::Round((Get-Item $final).Length/1MB,1)+'MB')
 Mount-WindowsImage -ImagePath $final -Index 1 -Path $mnt -ReadOnly | Out-Null
 $ds=Test-Path "$mnt\deploy-screen.ps1"; $bf=Test-Path "$mnt\brand-fonts\GoogleSans-Variable.ttf"; $wm=Test-Path "$mnt\brand-fonts\wordmark.pathdata"
 $noedge=-not (Test-Path "$mnt\edge"); $sshd=Test-Path "$mnt\Windows\System32\OpenSSH\sshd.exe"
 $dbc=Get-Content "$mnt\Windows\System32\deploy-boot.ps1" -Raw
 $e1=$null;[System.Management.Automation.Language.Parser]::ParseInput($dbc,[ref]$null,[ref]$e1)|Out-Null
 $dsc=Get-Content "$mnt\deploy-screen.ps1" -Raw
 $e2=$null;[System.Management.Automation.Language.Parser]::ParseInput($dsc,[ref]$null,[ref]$e2)|Out-Null
 $drv=@(Get-WindowsDriver -Path $mnt -EA SilentlyContinue).Count
 Log ("VERIFY screen=$ds fonts=$bf wordmark=$wm edgeRemoved=$noedge sshd=$sshd drivers=$drv bootErr=$(@($e1).Count) screenErr=$(@($e2).Count) placeholder=$([bool]($dbc -match '##WINPE_PASS##'))")
 Dismount-WindowsImage -Path $mnt -Discard | Out-Null
 Copy-Item $final 'C:\WinPE-src\winpe-deploy-final.wim' -Force
 $h=(Get-FileHash $final -Algorithm SHA256).Hash; $h2=(Get-FileHash 'C:\WinPE-src\winpe-deploy-final.wim' -Algorithm SHA256).Hash
 Log ("promoted USB-src hashMatch=$($h -eq $h2)")
 $wds=Get-Service WDSServer -EA SilentlyContinue; $run=($wds -and $wds.Status -eq 'Running')
 if($run){ Stop-Service WDSServer -Force; Start-Sleep 4; Log 'WDS stopped' }
 Copy-Item $final $live -Force
 $h3=(Get-FileHash $live -Algorithm SHA256).Hash
 Log ("promoted PXE hashMatch=$($h -eq $h3)")
 if($run){ Start-Service WDSServer; Log ('WDS='+(Get-Service WDSServer).Status) }
 Remove-Item $work -Force -EA SilentlyContinue
 Log ('final sha256='+$h)
 Log ('C: free='+[math]::Round((Get-PSDrive C).Free/1GB,1)+'GB')
 Log 'DONE wpf-bake'
}catch{ Log ('ERROR: '+$_.Exception.Message); try{Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard -EA SilentlyContinue|Out-Null}catch{}; try{ if((Get-Service WDSServer -EA SilentlyContinue).Status -ne 'Running'){Start-Service WDSServer} }catch{} }