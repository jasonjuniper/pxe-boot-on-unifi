$log="C:\WinPE-src\usb.log"
function Log($m){ "$(Get-Date -Format o)  $m" | Out-File $log -Append -Encoding utf8 }
try {
  Log "START usb build"
  $adkMedia='C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\Media'
  $work='C:\WinPE_usb\media'
  if(-not (Test-Path $adkMedia)){ Log "ADK Media missing: $adkMedia"; return }
  if(Test-Path 'C:\WinPE_usb'){ Remove-Item 'C:\WinPE_usb' -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  Log "Copying ADK media template..."
  Copy-Item "$adkMedia\*" $work -Recurse -Force
  New-Item -ItemType Directory -Force -Path "$work\sources" | Out-Null
  Log "Copying deploy-ready WIM as boot.wim..."
  Copy-Item 'C:\WinPE-src\winpe-deploy-final.wim' "$work\sources\boot.wim" -Force
  # Secure Boot: use proven CA-2023 boot manager as the UEFI loader
  Copy-Item 'C:\RemoteInstall\boot_EX\x64\bootmgfw_EX.efi' "$work\EFI\Boot\bootx64.efi" -Force
  Log "Replaced EFI\Boot\bootx64.efi with CA-2023 bootmgfw_EX"
  # verify media BCD has winload path
  $mbcd = "$work\EFI\Microsoft\Boot\BCD"
  if(Test-Path $mbcd){
    $dump = & bcdedit /store $mbcd /enum all 2>&1 | Out-String
    $g = ([regex]::Match($dump,'Windows Boot Loader[\s\S]*?identifier\s+(\{[0-9a-f-]+\})')).Groups[1].Value
    if($dump -notmatch 'system32\\boot\\winload\.efi' -and $g){ & bcdedit /store $mbcd /set $g path \windows\system32\boot\winload.efi 2>&1 | Out-Null; Log "added winload path to media BCD ($g)" }
    else { Log "media BCD winload path OK" }
  } else { Log "WARN: media BCD not found at $mbcd" }

  # --- SAFETY: pick the USB disk only ---
  $usb = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -lt 64GB -and -not $_.IsSystem -and -not $_.IsBoot }
  if(@($usb).Count -ne 1){ Log ("ABORT: expected exactly 1 USB disk, found " + @($usb).Count); return }
  Log ("Target USB: disk " + $usb.Number + " " + $usb.FriendlyName + " " + [math]::Round($usb.Size/1GB,1) + "GB")
  Log "Clearing + formatting FAT32..."
  Clear-Disk -Number $usb.Number -RemoveData -RemoveOEM -Confirm:$false
  Initialize-Disk -Number $usb.Number -PartitionStyle MBR
  $part = New-Partition -DiskNumber $usb.Number -UseMaximumSize -IsActive -AssignDriveLetter
  Start-Sleep 2
  Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'JUNIPER-PE' -Confirm:$false | Out-Null
  $drv = (Get-Partition -DiskNumber $usb.Number | Where-Object DriveLetter).DriveLetter
  Log ("Formatted. Drive letter: " + $drv)
  Log "Copying media to USB (robocopy)..."
  & robocopy $work ($drv + ':\') /E /NFL /NDL /NJH /NJS /R:2 /W:2 | Out-Null
  $bx = Test-Path ($drv + ':\EFI\Boot\bootx64.efi'); $bw = Test-Path ($drv + ':\sources\boot.wim')
  Log ("USB verify: EFI\Boot\bootx64.efi=" + $bx + "  sources\boot.wim=" + $bw)
  Log "DONE usb build"
} catch { Log ("ERROR: " + $_.Exception.Message) }
