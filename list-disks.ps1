Import-Module Storage -ErrorAction SilentlyContinue
Get-Disk | ForEach-Object {
    $gb = [math]::Round($_.Size / 1GB, 1)
    Write-Host "Disk $($_.Number): $($_.FriendlyName)  Bus=$($_.BusType)  $gb GB"
}
Write-Host "---"
Get-Partition | ForEach-Object {
    $ltr = if ($_.DriveLetter) { $_.DriveLetter } else { '(none)' }
    $mb = [math]::Round($_.Size / 1MB)
    Write-Host "  Disk $($_.DiskNumber) Part $($_.PartitionNumber): $ltr  $mb MB"
}
