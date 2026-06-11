@echo off
echo.
echo  ==========================================
echo   Juniper Design - PC Deployment System
echo  ==========================================
echo.
echo  Initializing WinPE networking...
wpeinit
echo.
echo  Starting deployment bootstrap...
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Windows\System32\deploy-boot.ps1
echo.
echo  Press any key to reboot...
pause > nul
wpeutil reboot
