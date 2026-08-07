$ErrorActionPreference='Stop'
$log='C:\WinPE-src\edge-inject.log'
function Log($m){ "$(Get-Date -f o)  $m" | Out-File $log -Append -Encoding utf8 }
Set-Content $log ''
try{
  $live='C:\RemoteInstall\Boot\x64\Images\winpe-deploy-final.wim'
  $work='C:\WinPE-src\winpe-edge-work.wim'
  $mnt='C:\WinPE-mnt'
  Log 'START edge-inject'
  $bak='C:\WinPE-src\winpe-deploy-final.wim.bak-preEdge'
  if(-not (Test-Path $bak)){ Copy-Item $live $bak -Force; Log "backed up live WIM -> $bak" } else { Log "backup exists: $bak" }
  if(Test-Path $work){ Remove-Item $work -Force }
  Copy-Item $live $work -Force
  Log ('copied live -> work ' + [math]::Round((Get-Item $work).Length/1MB,1) + ' MB')
  New-Item -ItemType Directory -Force $mnt | Out-Null
  Get-WindowsImage -Mounted -EA SilentlyContinue | ? { $_.Path -eq $mnt } | % { Dismount-WindowsImage -Path $mnt -Discard -EA SilentlyContinue }
  Mount-WindowsImage -ImagePath $work -Index 1 -Path $mnt | Out-Null
  Log 'mounted work WIM'
  $credf='C:\WinPE-src\deploy-boot-cred.ps1'
  if(-not (Test-Path $credf)){ throw 'missing deploy-boot-cred.ps1' }
  $c=Get-Content $credf -Raw
  if($c -match '##WINPE_PASS##'){ throw 'cred file still has placeholder' }
  [IO.File]::WriteAllText("$mnt\Windows\System32\deploy-boot.ps1",$c,[Text.UTF8Encoding]::new($false))
  Log ('deploy-boot.ps1 injected; imaging-screen ref=' + [bool]($c -match 'imaging-screen'))
  $scr='C:\deploy\scripts\winpe\imaging-screen.html'
  if(Test-Path $scr){ Copy-Item $scr "$mnt\imaging-screen.html" -Force; Log ('imaging-screen.html injected ' + [math]::Round((Get-Item $scr).Length/1KB,0) + ' KB') } else { Log 'WARN: imaging-screen.html missing' }
  $edgeApp=$null
  foreach($b in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application","$env:ProgramFiles\Microsoft\Edge\Application")){ if($b -and (Test-Path (Join-Path $b 'msedge.exe'))){ $edgeApp=$b; break } }
  if($edgeApp){ Log "staging Edge from $edgeApp"; & robocopy $edgeApp "$mnt\edge" /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null; Log ('Edge staged msedge.exe=' + (Test-Path "$mnt\edge\msedge.exe")) } else { Log 'WARN: Edge not found' }
  Log 'dismount /save (takes a while)...'
  Dismount-WindowsImage -Path $mnt -Save | Out-Null
  Log ('saved work WIM ' + [math]::Round((Get-Item $work).Length/1MB,1) + ' MB')
  Mount-WindowsImage -ImagePath $work -Index 1 -Path $mnt -ReadOnly | Out-Null
  $db=Test-Path "$mnt\Windows\System32\deploy-boot.ps1"; $sc=Test-Path "$mnt\imaging-screen.html"; $ed=Test-Path "$mnt\edge\msedge.exe"
  $dbc=Get-Content "$mnt\Windows\System32\deploy-boot.ps1" -Raw
  $errs=$null; [System.Management.Automation.Language.Parser]::ParseInput($dbc,[ref]$null,[ref]$errs) | Out-Null
  Log ("VERIFY deploy-boot=$db screen=$sc edge=$ed placeholder=" + [bool]($dbc -match '##WINPE_PASS##') + " parseErrors=" + @($errs).Count)
  Dismount-WindowsImage -Path $mnt -Discard | Out-Null
  Log 'DONE edge-inject'
}catch{ Log ('ERROR: ' + $_.Exception.Message); try{ Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard -EA SilentlyContinue | Out-Null }catch{} }