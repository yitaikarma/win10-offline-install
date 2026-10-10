@echo off
rem ---------------------------------------------------------------------------
rem Double-click launcher for Upgrade-DshWebOffline.ps1
rem
rem Bring a NEW bundle to the air-gapped host, put this launcher next to the new
rem bundle's Upgrade-DshWebOffline.ps1, and double-click it. It backs up
rem %USERPROFILE%\.dsh first, stops the Web UI, installs the new version beside
rem the old one and switches the launcher over.
rem
rem Useful arguments (see the script header for the full list):
rem     upgrade.cmd -DryRun        check the bundle and print the plan only
rem     upgrade.cmd -Rollback      switch back to a previously installed version
rem     upgrade.cmd -List          list the installed versions
rem
rem ASCII only on purpose: .cmd files are read in the OEM code page and
rem non-ASCII text here breaks on some systems.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

echo ============================================
echo  DeepSeek Harness (web) offline upgrade
echo  folder: %~dp0
echo ============================================
echo.

if not exist "%~dp0Upgrade-DshWebOffline.ps1" (
    echo [ERROR] Upgrade-DshWebOffline.ps1 is not next to this launcher.
    echo         Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] node is not on PATH.
    echo         Open PowerShell and run:  nvm use ^<version^>
    echo         then double-click this launcher again.
    echo.
    pause
    exit /b 1
)

for /f "delims=" %%v in ('node -v') do set NODEV=%%v
echo Using node %NODEV%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upgrade-DshWebOffline.ps1" %*
set RC=%ERRORLEVEL%

echo.
echo ============================================
if not "%RC%"=="0" (
    echo  FAILED - exit code %RC%
    echo  Scroll up for the error text. The previous version is still installed;
    echo  run  upgrade.cmd -Rollback  if the Web UI does not come back.
) else (
    echo  Finished successfully.
)
echo ============================================
echo.
pause
endlocal
