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

:: ===========================================================================
:: OOBE / no-Microsoft-account hardening (machine-wide, SYSTEM context)
:: Runs once post-OOBE, before the login screen and before the orchestrator
:: arms junadmin autologon. Suppresses the post-OOBE "Let's finish setting up
:: your device" SCOOBE nag, Windows consumer/Spotlight content, the OneDrive
:: personal first-run, and the Office/M365 first-run sign-in. Local accounts
:: only - no Microsoft account is ever introduced. All keys idempotent.
:: ===========================================================================
echo %DATE% %TIME%  [INFO ]  [SetupComplete         ]  Applying OOBE no-MSA / first-run nag suppression >> "%LOG%"

:: "Let's finish setting up your device" (SCOOBE) engagement prompts
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" /v ScoobeSystemSettingEnabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1

:: Windows consumer features / Spotlight / soft-landing suggestion content
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerFeatures /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1

:: OneDrive: stop the personal-account first-run/auto-setup nag (does NOT uninstall OneDrive)
reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v DisablePersonalSync /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1

:: Office / Microsoft 365 sign-in policy.
::   0 = both org + personal allowed   1 = personal (MSA) only
::   2 = ORGANIZATIONAL ID ONLY        3 = sign-in disabled entirely
:: CORRECTED 2026-07-20: this was 3, which blocks ALL sign-in - including the work
:: account. Microsoft 365 Apps for business is licensed PER USER and activates by
:: signing in with the work account, so 3 meant Office installed but could never
:: activate. 2 keeps the original intent (no personal Microsoft accounts) while
:: still allowing the M365 work account needed for activation.
reg add "HKLM\SOFTWARE\Policies\Microsoft\office\16.0\common\signin" /v SignInOptions /t REG_DWORD /d 2 /f >> "%LOG%" 2>&1

echo %DATE% %TIME%  [INFO ]  [SetupComplete         ]  OOBE no-MSA / first-run nag suppression applied >> "%LOG%"

:: Verify the orchestrator script was staged by deploy.ps1
if not exist "%ORCH%" (
    echo %DATE% %TIME%  [ERROR]  [SetupComplete         ]  orchestrator.ps1 not found at %ORCH% >> "%LOG%"
    exit /b 1
)

:: Bootstrap: creates the JuniperImaging scheduled task and runs first phase
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ORCH%" -Bootstrap

echo %DATE% %TIME%  [INFO ]  [SetupComplete         ]  Bootstrap complete >> "%LOG%"
exit /b 0
