@echo off
rem ---------------------------------------------------------------------------
rem Double-click launcher for Upgrade-OpenClawOffline.ps1
rem
rem Put this file next to Upgrade-OpenClawOffline.ps1 (same folder) and
rem double-click it. Run it from the NEW bundle folder on the air-gapped host.
rem
rem It backs up state first, then drives the official updater with the release
rem artifact this bundle carries. Rollback is backup-only: the upgrade migrates
rem the state database forward and older builds refuse to open it afterwards.
rem
rem For a rehearsal that changes nothing, run in PowerShell:
rem     powershell -ExecutionPolicy Bypass -File .\Upgrade-OpenClawOffline.ps1 -DryRun
rem
rem ASCII only on purpose: .cmd files are read in the OEM code page and
rem non-ASCII text here breaks on some systems.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

echo ============================================
echo  OpenClaw offline upgrade
echo  folder: %~dp0
echo ============================================
echo.

if not exist "%~dp0Upgrade-OpenClawOffline.ps1" (
    echo [ERROR] Upgrade-OpenClawOffline.ps1 is not next to this launcher.
    echo         Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0bundle-manifest.json" (
    echo [ERROR] bundle-manifest.json is missing - this does not look like a bundle.
    echo         Point the upgrade at the folder the builder produced.
    echo.
    pause
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] node is not on PATH. Open PowerShell and run:
    echo             nvm use 26.7.0
    echo         then double-click this launcher again.
    echo.
    pause
    exit /b 1
)

for /f "delims=" %%v in ('node -v') do set NODEV=%%v
echo Using node %NODEV%
echo.
echo This will:
echo   1. back up %USERPROFILE%\.openclaw  (the only way back)
echo   2. stop the Gateway and wait for it to exit
echo   3. run the updater preflight, then apply the update
echo   4. reinstall the Gateway service and verify
echo.
echo Rollback is BACKUP-ONLY. Do not continue without the backup step.
echo.
set /p CONFIRM=Type YES to continue:
if /i not "%CONFIRM%"=="YES" (
    echo.
    echo Aborted.
    echo.
    pause
    exit /b 1
)

echo.
powershell -ExecutionPolicy Bypass -File "%~dp0Upgrade-OpenClawOffline.ps1"
set RC=%ERRORLEVEL%

echo.
echo ============================================
if not "%RC%"=="0" (
    echo  FAILED - exit code %RC%
    echo  Scroll up for the error text.
    echo  Nothing was rolled back automatically - see the notes above.
) else (
    echo  Finished successfully.
)
echo ============================================
echo.
pause
endlocal
