@echo off
rem Etto's Playhouse - undo the most recent sync (resubscribes what it removed, restores addonlist.txt).
"%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0EttoSync.ps1" -Restore %*
echo.
pause
