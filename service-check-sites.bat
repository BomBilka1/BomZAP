@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\BomZAP-check.ps1"
echo.
pause
