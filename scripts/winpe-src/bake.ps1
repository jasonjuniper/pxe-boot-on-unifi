$log="C:\WinPE-src\bake.log"
function Log($m){ "$(Get-Date -Format o)  $m" | Out-File $log -Append -Encoding utf8 }
try {
  Log "START bake-cred"
  $src='C:\WinPE-src\winpe-deploy-final.wim'; $mnt='C:\WinPE-mnt'
  New-Item -ItemType Directory -Force -Path $mnt | Out-Null
  Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $mnt } | ForEach-Object { Dismount-WindowsImage -Path $mnt -Discard -ErrorAction SilentlyContinue }
  Mount-WindowsImage -ImagePath $src -Index 1 -Path $mnt | Out-Null
  Copy-Item 'C:\WinPE-src\deploy-boot-cred.ps1' "$mnt\Windows\System32\deploy-boot.ps1" -Force
  $chk = Get-Content "$mnt\Windows\System32\deploy-boot.ps1" -Raw
  Log ("baked deploy-boot.ps1 len=" + $chk.Length + " placeholder=" + [bool]($chk -match '##WINPE_PASS##'))
  Dismount-WindowsImage -Path $mnt -Save | Out-Null
  Remove-Item 'C:\WinPE-src\deploy-boot-cred.ps1' -Force -ErrorAction SilentlyContinue
  Log "scrubbed temp cred file"
  Log "DONE bake-cred"
} catch { Log ("ERROR: " + $_.Exception.Message); try { Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard } catch {} }
