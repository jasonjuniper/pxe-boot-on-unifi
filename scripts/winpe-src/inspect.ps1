$log="C:\WinPE-src\inspect.log"
function Log($m){ "$(Get-Date -Format o)  $m" | Out-File $log -Append -Encoding utf8 }
try {
  Log "START inspect"
  Copy-Item 'C:\WinPE-src\Winre.wim' 'C:\WinPE-src\winpe-build.wim' -Force
  $mnt='C:\WinPE-mnt'; New-Item -ItemType Directory -Force -Path $mnt | Out-Null
  Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mnt } | ForEach-Object { Dismount-WindowsImage -Path $mnt -Discard -ErrorAction SilentlyContinue }
  Log "Mounting winpe-build.wim..."
  Mount-WindowsImage -ImagePath 'C:\WinPE-src\winpe-build.wim' -Index 1 -Path $mnt | Out-Null
  Log "Mounted. Checking key components:"
  Log ("  powershell.exe: " + (Test-Path "$mnt\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"))
  Log ("  wmic/wbem:      " + (Test-Path "$mnt\Windows\System32\wbem\WmiPrvSE.exe"))
  Log ("  dism.exe:       " + (Test-Path "$mnt\Windows\System32\Dism.exe"))
  Log ("  wpeinit.exe:    " + (Test-Path "$mnt\Windows\System32\wpeinit.exe"))
  Log ("  startnet.cmd:   " + (Test-Path "$mnt\Windows\System32\startnet.cmd"))
  Log ("  curl.exe:       " + (Test-Path "$mnt\Windows\System32\curl.exe"))
  Log "Installed WinPE packages:"
  try { Get-WindowsPackage -Path $mnt | Select-Object -ExpandProperty PackageName | ForEach-Object { Log ("  PKG: " + $_) } } catch { Log ("pkg err: " + $_.Exception.Message) }
  Dismount-WindowsImage -Path $mnt -Discard | Out-Null
  Log "DONE inspect"
} catch { Log ("ERROR: " + $_.Exception.Message); try { Dismount-WindowsImage -Path 'C:\WinPE-mnt' -Discard } catch {} }
