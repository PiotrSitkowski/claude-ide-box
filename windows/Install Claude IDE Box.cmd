@echo off
rem Double-click to install, repair or update Claude IDE Box on Windows.
rem Uninstall: run this file with -Uninstall.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0support\install.ps1" %*
