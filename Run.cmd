@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" %*
set "RESULT=%ERRORLEVEL%"
popd
echo.
if not "%RESULT%"=="0" echo FFXIV IDA Runner failed with exit code %RESULT%.
pause
exit /b %RESULT%
