@echo off
setlocal
cd /d "%~dp0"

"mods\CustomAssets\tools\custom-assets-patcher.exe"
set "CA_EXIT=%errorlevel%"

echo.
echo Press any key to close...
pause >nul
exit /b %CA_EXIT%
