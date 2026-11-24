@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
if errorlevel 9009 (
    echo.
    echo [ERROR] PowerShell not found on this system.
    echo         Windows 10/11 should include it. Try running: powershell -v
    pause
)
