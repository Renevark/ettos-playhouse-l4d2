@echo off
rem Etto's Playhouse - copy Etto's full client setup (optional cosmetics, weapons, sounds) and its load order.
rem Add -Strict to also remove everything else (exact mirror). Restore.cmd undoes it.
"%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0EttoSync.ps1" -Parity %*
echo.
pause
