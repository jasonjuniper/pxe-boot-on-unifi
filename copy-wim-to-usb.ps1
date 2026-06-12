$src = '\\192.168.5.141\winpemedia$\sources\boot.wim'
$dst = 'D:\sources\boot.wim'

# Reconnect share fresh
net use \\192.168.5.141\winpemedia$ /delete 2>$null
net use \\192.168.5.141\winpemedia$ /persistent:no

$srcSize = (Get-Item $src).Length
Write-Host "Source: $src  ($([math]::Round($srcSize/1MB)) MB)"
Write-Host "Destination: $dst"
Write-Host "Copying..."

Copy-Item $src $dst -Force
$dstSize = (Get-Item $dst).Length
if ($dstSize -eq $srcSize) {
    Write-Host "Done. $([math]::Round($dstSize/1MB)) MB verified." -ForegroundColor Green
} else {
    Write-Host "Size mismatch! src=$srcSize dst=$dstSize" -ForegroundColor Red
}
