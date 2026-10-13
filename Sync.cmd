@echo off
rem Etto's Playhouse - L4D2 Workshop sync (Standard mode). Add -Strict or -DryRun after the script path to change mode.
"%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0EttoSync.ps1" %*
echo.
pause
