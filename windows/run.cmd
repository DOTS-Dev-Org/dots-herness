@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DotsHarness\run.ps1" %*
exit /b %ERRORLEVEL%
