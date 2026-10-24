@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\DotsHarness\scripts\package-zip.ps1" %*
exit /b %ERRORLEVEL%
