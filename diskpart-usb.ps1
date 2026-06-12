$out    = 'C:\Windows\Temp\dp-out.txt'
$err    = 'C:\Windows\Temp\dp-err.txt'
$script = 'C:\Windows\Temp\dp-cmds.txt'
'list disk' | Set-Content $script -Encoding ASCII
$p = Start-Process -FilePath 'C:\Windows\System32\diskpart.exe' `
     -ArgumentList '/s', $script `
     -NoNewWindow -Wait -PassThru `
     -RedirectStandardOutput $out `
     -RedirectStandardError $err
"ExitCode: $($p.ExitCode)"
Get-Content $out
Get-Content $err
