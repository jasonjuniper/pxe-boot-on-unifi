@echo off
echo.
echo  ==========================================
echo   Juniper Design - PC Deployment System
echo  ==========================================
echo.
echo  Initializing WinPE networking...
wpeinit
echo.

rem  ── Branded deploy UI (requires WinPE-Scripting + HTA injected by build script)
if exist X:\Windows\System32\deploy-ui.hta (
    echo  Launching branded deployment UI...
    X:\Windows\System32\mshta.exe X:\Windows\System32\deploy-ui.hta
    goto :reboot
)

rem  ── Fallback: plain PowerShell console
echo  (deploy-ui.hta not found - falling back to console mode)
echo  Starting deployment script...
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Windows\System32\deploy.ps1
echo.
echo  Deployment script exited.
echo  Press any key to reboot...
pause > nul

:reboot
wpeutil reboot
