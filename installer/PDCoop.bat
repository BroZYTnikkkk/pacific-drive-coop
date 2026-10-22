@echo off
rem Pacific Drive Co-op: install / update, role, logs, uninstall. Read PDCoop.ps1 to see what it does.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PDCoop.ps1" %*
pause
