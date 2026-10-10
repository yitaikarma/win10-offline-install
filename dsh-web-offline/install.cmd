@echo off
rem ---------------------------------------------------------------------------
rem Double-click launcher for Install-DshWebOffline.ps1
rem
rem Put this file next to Install-DshWebOffline.ps1 (same folder) and
rem double-click it. It runs the PowerShell script from its own folder, so
rem -BundleDir resolves to the right place with no arguments.
rem
rem Extra arguments are forwarded, for example:
rem     install.cmd -BaseUrl http://10.0.0.20:8000/v1 -ModelId qwen3-32b
rem
rem ASCII only on purpose: .cmd files are read in the OEM code page and
rem non-ASCII text here breaks on some systems.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

echo ============================================
echo  DeepSeek Harness (web) offline install
echo  folder: %~dp0
echo ============================================
echo.

if not exist "%~dp0Install-DshWebOffline.ps1" (
    echo [ERROR] Install-DshWebOffline.ps1 is not next to this launcher.
    echo         Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] node is not on PATH.
    echo         Open PowerShell and run:
    echo             nvm install 26.7.0
    echo             nvm use 26.7.0
    echo         then double-click this launcher again.
    echo.
    pause
    exit /b 1
)

for /f "delims=" %%v in ('node -v') do set NODEV=%%v
echo Using node %NODEV%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DshWebOffline.ps1" %*
set RC=%ERRORLEVEL%

echo.
echo ============================================
if not "%RC%"=="0" (
    echo  FAILED - exit code %RC%
    echo  Scroll up for the error text.
) else (
    echo  Finished successfully.
    echo  Open the Web UI URL printed above in a browser.
)
echo ============================================
echo.
pause
endlocal
