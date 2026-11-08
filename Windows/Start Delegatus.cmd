@echo off
setlocal DisableDelayedExpansion
set "DELEGATUS_GUI=0"
set "DELEGATUS_PACKAGE_DIR=%~dp0"
set "DELEGATUS_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "DELEGATUS_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%DELEGATUS_POWERSHELL%" (
  echo Windows PowerShell 5.1 was not found. Windows 10 or 11 is required.
  pause
  exit /b 1
)
"%DELEGATUS_POWERSHELL%" -NoLogo -NoProfile -STA -Command "try { $p = [IO.Path]::Combine($env:DELEGATUS_PACKAGE_DIR, 'Resources', 'Launch-Delegatus.ps1'); $s = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s)) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
set "DELEGATUS_EXIT=%ERRORLEVEL%"
if not "%DELEGATUS_EXIT%"=="0" (
  echo.
  echo Delegatus Launcher could not complete. The error above was kept visible.
  pause
)
exit /b %DELEGATUS_EXIT%
