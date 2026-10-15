@echo off
setlocal
rem Use Windows PowerShell's own modules, even when launched by PowerShell 7.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-venice-relay.ps1" %*
set "relayExitCode=%errorlevel%"
if /I "%~1"=="-CheckOnly" exit /b %relayExitCode%
pause
exit /b %relayExitCode%
