@echo off
rem Double-click to remove Claude IDE Box. Projects are copied to Documents first.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0support\install.ps1" -Uninstall
