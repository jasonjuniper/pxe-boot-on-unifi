@echo off
:: SetupComplete.cmd - Juniper Imaging Bootstrap
:: Windows automatically runs this file after OOBE, before the login screen,
:: as SYSTEM. It hands off to the PowerShell orchestrator which creates a
:: startup scheduled task and kicks off the first imaging phase.
::
:: This file is placed on the target at C:\Windows\Setup\Scripts\SetupComplete.cmd
:: by deploy.ps1 during the WinPE imaging phase.

setlocal

set SETUP_ROOT=C:\ProgramData\JuniperSetup
set LOG=%SETUP_ROOT%\imaging.log
set ORCH=%SETUP_ROOT%\orchestrator.ps1

:: Ensure setup dir exists (should already from WinPE, but safety net)
if not exist "%SETUP_ROOT%" mkdir "%SETUP_ROOT%"

:: Write bootstrap entry to master log
echo %DATE% %TIME%  [INFO ]  [SetupComplete         ]  SetupComplete.cmd fired - bootstrapping JuniperImaging >> "%LOG%"

:: Verify the orchestrator script was staged by deploy.ps1
if not exist "%ORCH%" (
    echo %DATE% %TIME%  [ERROR]  [SetupComplete         ]  orchestrator.ps1 not found at %ORCH% >> "%LOG%"
    exit /b 1
)

:: Bootstrap: creates the JuniperImaging scheduled task and runs first phase
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ORCH%" -Bootstrap

echo %DATE% %TIME%  [INFO ]  [SetupComplete         ]  Bootstrap complete >> "%LOG%"
exit /b 0
