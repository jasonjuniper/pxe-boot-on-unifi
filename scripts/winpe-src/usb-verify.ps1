$log='C:\WinPE-src\usb-verify.log'
Set-Content $log ''
function Log($m){ "$(Get-Date -f o)  $m" | Out-File $log -Append -Encoding utf8 }
try{
 $src='C:\WinPE-src\winpe-deploy-final.wim'
 $vol=Get-Volume | ? { $_.FileSystemLabel -eq 'JUNIPER-PE' -and $_.DriveType -eq 'Removable' } | Select-Object -First 1
 if(-not $vol){ Log 'ERROR: JUNIPER-PE volume not found'; return }
 $drv=$vol.DriveLetter
 try{ Write-VolumeCache -DriveLetter $drv -EA SilentlyContinue }catch{}
 $usb="${drv}:\sources\boot.wim"
 Log ("USB boot.wim=$usb size=" + [math]::Round((Get-Item $usb).Length/1MB,1) + 'MB')
 $hs=(Get-FileHash $src -Algorithm SHA256).Hash
 $hu=(Get-FileHash $usb -Algorithm SHA256).Hash
 Log ("srcHash=$hs")
 Log ("usbHash=$hu")
 Log ("HASH MATCH (safe to boot)=" + ($hs -eq $hu))
 Log 'DONE verify'
}catch{ Log ('ERROR: '+$_.Exception.Message) }